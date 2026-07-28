# kubernetes-cluster — design & migration plan

Extracting the k3s cluster module from `nixos-config` into a generic, reusable
flake that supports **multiple named clusters**, then using it to split the
single `sea.fudo.org` cluster into a home cluster and a DC cluster.

---

## 1. Where things stand

The whole cluster lives in `nixos-config/services/kubernetes/` (~770 lines):

| File | Contents |
|------|----------|
| `default.nix` | Node-role computation, GPU device→label table, submodule wiring |
| `options.nix` | `fudo.services.kubernetes.*` option declarations |
| `core.nix` | k3s service, CoreDNS configmap, manifest applier, DNS zones, ceph kernel bits |
| `gateway.nix` | nginx reverse proxy + NAT port-forward on the gateway host |
| `nvidia.nix` | containerd + CDI + nvidia runtime, GPU node tagger |

It is imported unconditionally by `system/services.nix` on every host, and
configured from three levels:

- `domain/sea.fudo.org/global.nix` — the topology (masters, nodes, gpuNodes,
  ingressHosts, nodeLabels, ~70 internal + 4 external endpoints)
- `domain/sea.fudo.org/config.nix` — the settings (zone, gateway, DNS, tagger)
- `hosts/*/config.nix` — `stateDirectory`, on 9 hosts

The single-cluster assumption is structural, not incidental: every option is a
bare list keyed on hostname, and role is derived by `elem hostname cfg.masters`.
There is no place to hang a second cluster.

### Fudo coupling inventory

Everything the module reaches into that is *not* generic NixOS:

| Touchpoint | Used in | Disposition |
|---|---|---|
| `pkgs.lib.getHostIpv4` / `getHostFqdn` | default, core, gateway, nvidia | Wrapper resolves → `nodes.<n>.address` / `.fqdn` |
| `config.instance.hostname` | default | Generic `nodeName`, defaulting to `networking.hostName` |
| `config.fudo.hosts.<h>.domain` | default (`localDomainName`) | Generic `gateway.internalDomain` |
| `mkHostPasswdFile` (`lib/utils.nix`) | core (k3s token) | Wrapper generates; generic takes a `tokenFile` path |
| `fudo.secrets.host-secrets.<h>` | core, nvidia | Wrapper |
| `fudo.zones.<zone>` | core (`globalConfig`) | Wrapper (`dns.nix`) |
| `fudo.services.nexus.host-aliases` | core | Wrapper |
| `fudo-secrets.target` systemd dep | core | Generic `tokenReadyUnits = listOf str` |
| `fudo.org/gpu.*` device→label table | default | Wrapper data → `nvidia.deviceLabels` |
| `static/cdi-nvidia-device-labeler.bb` | nvidia | **Moves** to this flake as a package |
| `ceph-mount.service` ordering | core | Generic, behind `storage.ceph.enable` |

The labeler script is already fully parameterised (`--hostname`, `--device-map`,
`--token`, `--kube-master`, `--cert`), so it ports as-is — only the JSON device
map it consumes is Fudo-specific, and that is already passed as a file.

Per `AGENTS.md`, this extraction moves in the desired direction: the resulting
module evaluates **without** the private `fudo-entities` input, because
addresses arrive as plain data instead of being looked up.

---

## 2. Target module API

Option root: `services.kubernetes-cluster`.

```nix
services.kubernetes-cluster = {
  # Identifies this host within cluster node sets.
  nodeName = mkOption { type = str; default = config.networking.hostName; };

  clusters = mkOption {
    default = { };
    type = attrsOf (submodule ({ name, config, ... }: {
      options = {
        enable  = mkEnableOption "cluster ${name}";
        verbose = mkEnableOption "verbose output";

        nodes = mkOption {
          type = attrsOf (submodule {
            options = {
              role       = mkOption { type = enum [ "server" "agent" ]; default = "agent"; };
              address    = mkOption { type = str; };                    # IPv4, for join + ingress records
              fqdn       = mkOption { type = nullOr str; default = null; };
              labels     = mkOption { type = listOf str; default = [ ]; };
              taints     = mkOption { type = listOf str; default = [ ]; };
              ingress    = mkOption { type = bool; default = false; };
              gpu.enable = mkOption { type = bool; default = false; };
              extraFlags = mkOption { type = listOf str; default = [ ]; };
            };
          });
        };

        # Runs `--cluster-init`. Defaults to the lexically first server —
        # deterministic, unlike `head` over a user-ordered list.
        primaryMaster  = mkOption { type = str; };

        tokenFile      = mkOption { type = str; };
        stateDirectory = mkOption { type = str; };
        apiPort        = mkOption { type = port; default = 6443; };
        tlsSans        = mkOption { type = listOf str; default = [ ]; };
        extraFlags     = mkOption { type = listOf str; default = [ ]; };

        # Units that must be up before k3s starts (fudo-secrets.target, agenix, …)
        tokenReadyUnits = mkOption { type = listOf str; default = [ ]; };

        dns = {
          upstream      = mkOption { type = str; default = "1.1.1.1"; };
          clusterDomain = mkOption { type = str; default = "cluster.local"; };
          corefile      = mkOption { type = nullOr lines; default = null; };  # escape hatch
        };

        manifests = mkOption {
          type = attrsOf (either path lines);
          default = { };
          description = "YAML applied by the primary master once k3s is up.";
        };

        gateway = {
          enable, host, externalHostname, zone, internalDomain, acme.enable
        };

        endpoints = {
          internal = listOf endpointType;   # { name; type = HTTP|TCP|UDP; port; }
          external = listOf endpointType;
        };

        storage.ceph.enable = mkOption { type = bool; default = false; };

        nvidia = {
          deviceLabels = mkOption { type = attrsOf (listOf str); default = { }; };
          baseLabels   = mkOption { type = listOf str; default = [ … ]; };
          tagger       = { enable; tokenFile; caCertFile; interval; };
        };
      };
    }));
  };

  # Read-only, for consumers that need to know what this host ended up as.
  membership = mkOption { readOnly = true; };
  #   null, or { cluster; isServer; isPrimary; isIngress; isGpu; }
};
```

### Why an attrset of nodes

The current parallel lists (`masters`, `nodes`, `gpuNodes`, `ingressHosts`,
`nodeLabels`) can silently desync — a host in `gpuNodes` but absent from `nodes`
gets a GPU stack and no kubelet. Folding them into one entry per node makes
that unrepresentable, and it is what lets `address`/`fqdn` be plain data rather
than an entity lookup, which is what frees the flake from `fudo-entities`.

### Assertions

These are the guardrails that make multi-cluster safe:

1. **This host appears in at most one cluster's `nodes`.** `services.k3s` is a
   NixOS singleton; two clusters on one host is not a config error to debug
   later, it is an eval error now.
2. `primaryMaster` names a node whose `role` is `"server"`.
3. Every node has a non-empty `address`.
4. Warn on an even number of servers (etcd quorum).
5. If any node sets `gpu.enable`, the cluster's `nvidia.tagger` is configured.

### Repository layout

```
flake.nix                 # nixpkgs only; no Fudo inputs
modules/
  default.nix             # entry; per-host membership resolution
  options.nix
  k3s.nix                 # from core.nix
  dns.nix                 # CoreDNS configmap
  manifests.nix           # /etc/k3s/*.yaml applier
  gateway.nix
  nvidia.nix
  storage.nix             # ceph RBD modules + mount helpers
lib/default.nix
pkgs/cdi-nvidia-device-labeler.nix
tests/two-clusters.nix
```

Outputs: `nixosModules.default`, `lib`, `packages.<system>.cdi-nvidia-device-labeler`,
`checks.<system>.two-clusters`.

---

## 3. Phased plan

### Phase 0 — decide (no code)

Blocking for phases 4+ only. Phases 1–3 proceed regardless.

- **Confirm ceph OSD/mon placement** (`ceph osd tree`, `ceph -s`). This decides
  which side keeps the existing cluster. See §4.1.
- Confirm which fluxcd/GitOps repo drives cluster workloads — the second cluster
  needs its own, or its own path within the existing one.
- Confirm `fimbria`'s site, and whether each cluster gets its own gateway.
- Pick a DNS zone for the second cluster (today: `zone = "sea.fudo.link"`,
  `nexusZones = [ "fudo.ninja" ]`, gateway `seattle.fudo.link.`).
- Pick cluster names. They appear in secret names and state paths, so choose
  once (suggested: `seattle` and `dc0`).

### Phase 1 — build the generic flake

1. Flake skeleton: nixpkgs-only input, `nixosModules.default`, `lib`.
2. Package `cdi-nvidia-device-labeler.bb` (moved from `nixos-config/static/`).
3. `options.nix` per §2.
4. Port `core.nix` → `k3s.nix` + `dns.nix` + `manifests.nix`, with every Fudo
   touchpoint from §1 replaced by an option.
5. Port `gateway.nix`, `nvidia.nix`, and the ceph bits → `storage.nix`.
6. Assertions.
7. **NixOS VM test** (`tests/two-clusters.nix`): three VMs — cluster A
   server + agent, cluster B server. Assert both clusters reach `Ready` and
   that neither sees the other's nodes. This is the test that proves the whole
   point of the refactor.
8. `README.md` with a full option reference.

**Gate:** `nix flake check` green.

### Phase 2 — Fudo wrapper in nixos-config

1. Add the flake to `flake.nix` inputs and `lib/modules.nix`.
2. Rewrite `services/kubernetes/` as a thin wrapper:
   - `options.nix` — `fudo.services.kubernetes.clusters.<name>`, keeping
     ergonomic list-shaped inputs where they read better
   - `translate.nix` — → `services.kubernetes-cluster.clusters.<name>`,
     filling `address`/`fqdn` via `getHostIpv4`/`getHostFqdn`
   - `dns.nix` — `fudo.zones` records + nexus aliases, per cluster
   - `secrets.nix` — per-cluster k3s token and tagger token
   - `nvidia-labels.nix` — the `fudo.org/gpu.*` device map as data
3. Keep a host-level `fudo.services.kubernetes.stateDirectory` default that
   applies to whichever cluster the host belongs to, so the 9 `hosts/*/config.nix`
   files need no change.

**Gate:** the flake evaluates.

### Phase 3 — move the existing cluster onto the named API

A **pure refactor with a byte-identical result**. Nothing about the running
cluster changes.

1. `domain/sea.fudo.org/global.nix`: lists → `clusters.<name>.nodes` attrset.
2. `domain/sea.fudo.org/config.nix`: nest settings under the cluster name; update
   `local-network.dnsFilterProxy.clusterUpstreams`, which reads
   `config.fudo.services.kubernetes.ingressHosts` today.
3. **Pin the k3s token secret name to `k3s-token`.** It is currently derived from
   `mkHostPasswdFile "k3s-token"`; if the cluster name leaks into that name, the
   token rotates and every node fails to rejoin. This is the single easiest way
   to take the cluster down during an otherwise no-op refactor.

**Gate — do not deploy until this is clean.** For all 11 nodes plus `fimbria`:

```bash
# before the change
nix build .#nixosConfigurations.<h>.config.system.build.toplevel --out-link /tmp/before-<h>
# after
nix build .#nixosConfigurations.<h>.config.system.build.toplevel --out-link /tmp/after-<h>
nvd diff /tmp/before-<h> /tmp/after-<h>
```

Every diff should be empty. A non-empty diff is a porting bug, not something to
deploy through.

### Phase 4 — stand up the second cluster

1. Add `clusters.<new>` with its own zone, gateway, token secret, and state
   directory — initially with no members.
2. Pick the first node. Drain and remove it from the old cluster:
   ```bash
   kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
   kubectl delete node <node>
   ```
3. Move the host between the two `nodes` attrsets in a single commit. Give it
   `role = "server"`; it becomes the new cluster's `primaryMaster`
   (`--cluster-init`).
4. **Wipe k3s state on that host before rebuilding.** `/var/lib/rancher/k3s` and
   the configured `stateDirectory` cache the old server URL and token; a node
   that keeps them will happily rejoin the cluster you just removed it from.
5. Repeat per node. Grow to 3 servers before putting real load on it.

### Phase 5 — migrate workloads, then move hardware

1. **Storage first.** The new cluster needs a working storage class before
   anything stateful lands on it.
2. Per workload: repoint flux, migrate PVC data, cut DNS.
3. Physical relocation last, once the DC-bound nodes are in their own cluster
   and drained of everything that should stay home.

---

## 4. Risks and gotchas

### 4.1 Migration direction (decide in phase 0)

Rack-mounted hosts leaving for the DC: **`rama`, `cellar`, `thunk-0`** — all
three currently *agents*. Staying home: `thing-0/1/2` (masters + ingress +
ceph-mon), `thing-3/4` (ceph-mon), `toothless`, `system3`, `grendal`.

Keeping the *existing* cluster on the DC side therefore means removing 8 of 11
nodes, including the entire control plane, and migrating etcd quorum across the
home uplink one master at a time. Standing up a fresh 3-node cluster in the DC
and leaving the existing cluster at home is dramatically less work and less
risky.

The counter-argument was ceph data locality — but etcd holds no bulk data, and
ceph data lives on the OSD disks, which travel with the hardware either way. A
Rook cluster can be re-formed around relocated OSDs. **Verify OSD placement
before committing to a direction.**

### 4.2 Ceph cannot span the WAN

Mons and OSDs need a low-latency, high-bandwidth link. The ceph cluster must
land wholly on one side of the split. Note that `ceph-mon=allowed` is labelled
on `thing-0..4`, all of which stay home.

### 4.3 Home uplink becomes the DC's path to everything

You described the new place's wireless internet as lousy. Anything home-side
that depends on a DC endpoint pays that cost on every request. The ~70 entries
in `kubeInternalEndpoints` need an endpoint-by-endpoint review — Home Assistant
reaching `wyoming-whisper-*`, `kokoro`, `piper`, `tts`, `stt`, and `ollama`
across a slow link will be very noticeable.

### 4.4 Smaller items

- `dnsFilterProxy.clusterUpstreams` must point at the *local* cluster's ingress
  nodes at each site, not a single global list.
- `fileSystems."/net/kube_media"` NFS-mounts from `thing-0.sea.fudo.org` on
  every `sea.fudo.org` host — check who still needs it after the split.
- `core.nix:106` orders k3s `before = [ "ceph-mount.service" ]`, but no
  `ceph-mount.service` is defined anywhere in `nixos-config`. Harmless (systemd
  ordering against an absent unit is a no-op) but worth cleaning up during the
  port.
- `services.k3s` is a NixOS singleton — one cluster per host, enforced by
  assertion (§2).
