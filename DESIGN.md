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

- ~~Confirm ceph OSD placement.~~ **Done — see §4.1.** The existing cluster
  follows ceph to the DC.
- **Resolve the DC capacity shortfall (§4.2).** Confirmed hard blocker on phase
  5: 110 TiB of HDD data against 118.23 TiB of DC HDD. Needs added hardware or a
  smaller `ceph-filesystem-data0`. Run `ceph osd crush rule dump` to size it.
- Confirm which fluxcd/GitOps repo drives cluster workloads — the second cluster
  needs its own, or its own path within the existing one.
- Confirm `fimbria`'s site, and whether each cluster gets its own gateway.
- Pick a DNS zone for the second cluster (today: `zone = "sea.fudo.link"`,
  `nexusZones = [ "fudo.ninja" ]`, gateway `seattle.fudo.link.`).
- Pick cluster names. They appear in secret names and state paths, so choose
  once (suggested: `seattle` and `dc0`).

### Phase 1 — build the generic flake ✅ written, not yet evaluated

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

### Phase 2 — Fudo wrapper in nixos-config ✅ written, not yet evaluated

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

### Phase 3 — move the existing cluster onto the named API ⚠️ written; diff gate not yet run

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

Every diff should be empty, with **one known exception**: on GPU nodes the
`gpu-node-tagger` unit's `ExecStart` necessarily changes, because the labeler is
now a packaged binary (`${labeler}/bin/cdi-nvidia-device-labeler`) rather than
`bb` invoked against a script path in `nixos-config/static/`. That diff should be
reviewed and accepted; any *other* non-empty diff is a porting bug, not something
to deploy through.

The TLS SAN flags are a second place to look closely. The original emitted them
as a single space-joined string inside one list element; the port emits one
element per SAN. These join to the same command line, so the unit should be
identical — but confirm rather than assume.

### Phase 4 — stand up the second cluster

Per §4.1 the *existing* cluster is the one bound for the DC, so the new cluster
is the **home** cluster and it receives 8 of the 11 nodes. Everything here
happens while all hosts are still on the home LAN.

0. **Migrate the control plane first.** `thing-0/1/2` are the current servers and
   all three are leaving the cluster. Promote `cellar`, `rama` and `thunk-0` to
   `role = "server"`, let etcd converge, then retire the `thing-*` servers one at
   a time keeping an odd member count. Do the same for the ceph mon label (§4.3).
   Only once the DC-bound trio owns both quorums does node peeling begin.
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
5. Repeat per node. Take `thing-0/1/2` early so the home cluster has 3 servers,
   then `thing-3/4`, `toothless`, `system3`, `grendal`.

Note that `thing-0/1/2` carry 52.75 TiB of OSDs. Those must be drained from ceph
(`ceph osd out`, wait for rebalance) *before* the hosts leave the old cluster,
and the DC-bound hosts have to have room for the data — see §4.2.

### Phase 5 — migrate workloads, then move hardware

1. **Storage first.** The home cluster needs a working storage class before
   anything stateful lands on it — a fresh Rook cluster on `thing-0/1/2`, subject
   to the SSD constraint in §4.2/§4.4.
2. Per workload: repoint flux, migrate PVC data, cut DNS.
3. **Physical relocation last**, once `cellar`/`rama`/`thunk-0` are the sole
   members of the existing cluster and hold the whole ceph cluster. Everything
   before this point happens on the home LAN.

---

## 4. Risks and gotchas

### 4.1 Migration direction — resolved: the existing cluster goes to the DC

Rack-mounted hosts leaving for the DC: **`rama`, `cellar`, `thunk-0`** — all
three currently *agents*. Staying home: `thing-0/1/2` (masters + ingress +
ceph-mon), `thing-3/4` (ceph-mon, no OSDs), `toothless`, `system3`, `grendal`
(GPU, no OSDs).

Raw OSD capacity from `ceph osd tree` (total 191.09 TiB):

| | HDD | SSD | Total | Share |
|---|---|---|---|---|
| → DC (cellar, rama, thunk-0) | 118.23 | 16.37 | **134.61** | 70.4% |
| stays home (thing-0/1/2) | 52.75 | 3.73 | **56.48** | 29.6% |

`cellar` alone is 51% of the cluster. Home cannot absorb the DC-bound data, so
the existing ceph cluster must go to the DC, and the k8s cluster should follow
it — keeping Rook's CRs, mon quorum and OSD metadata in the same etcd is the one
thing least worth gambling on.

An earlier draft argued the reverse on the grounds that migrating the control
plane would span etcd quorum across the home uplink. That was wrong: the cluster
reshuffling happens while every host is still on the home LAN, and the physical
relocation is the *last* step. Promoting `cellar`/`rama`/`thunk-0` to servers and
retiring `thing-0/1/2` is an ordinary on-LAN k3s operation.

### 4.2 The DC cannot hold the ceph data — hard blocker, needs hardware

All pools are `size 3 min_size 2`. From `ceph df`:

| Class | Raw size | Raw used | %used |
|---|---|---|---|
| hdd | 171 TiB | **110 TiB** | 64.3% |
| ssd | 20 TiB | 1.4 TiB | 7.0% |

Essentially all of it is `ceph-filesystem-data0` (33 TiB stored → 99 TiB raw)
and `ceph-blockpool` (4 TiB → 12 TiB).

After the split the DC has `cellar` (98.23) + `thunk-0` (20.01) = **118.23 TiB
of HDD** to hold **110 TiB of data — 93% full.** Ceph's `nearfull_ratio` is 0.85
and `backfillfull_ratio` is 0.90, so the backfill would not even complete; it
would stall and block writes. This conclusion holds regardless of CRUSH
topology.

Minimum HDD to add at the DC:

| Target | HDD needed | Short by |
|---|---|---|
| Clear nearfull (85%) | 129.4 TiB | ~11 TiB |
| Comfortable (70%) | 157.1 TiB | ~39 TiB |

**Still to confirm — the HDD failure domain:**

```bash
kubectl exec -n rook-ceph deployments/rook-ceph-tools -- ceph osd crush rule dump
```

- If **`osd`**: the 93% figure above is the whole problem, and ~11–39 TiB of
  added HDD resolves it. Most likely, since `ceph-filesystem-data0` reports 33
  TiB stored with 14 TiB still available, which host-domain math cannot produce
  given `cellar`'s dominance.
- If **`host`**: far worse. Two HDD hosts cannot place three replicas at all.
  Because `cellar` can hold at most one replica of any PG, usable capacity is
  bounded by `(total_hdd − cellar)/2` ≈ **10 TiB** against 37 TiB stored. That
  needs roughly **54 TiB of additional non-`cellar` HDD**, ideally spread over
  two hosts.

**Resolution (chosen): one additional rackmount HDD host at the DC.**

Home only needs 10–20 TB, so most data stays with the DC. Under `host` domain at
`size=3`, DC usable capacity is `(non-cellar HDD)/2` — `cellar` is capped at one
replica per PG no matter how large it grows:

| New server HDD | DC usable at size=3 |
|---|---|
| 0 | 10.0 TiB |
| **24 TiB** | **22.0 TiB** |
| 40 TiB | 30.0 TiB |
| 60 TiB | 40.0 TiB |

If home takes ~15 TiB of the ~37 TiB total, the DC needs ~22 TiB, so **~24 TiB in
the new server sustains full `size=3`**. Reducing redundancy is therefore
avoidable rather than merely deferrable, and it skips a later 22 TiB rebalance.

Two corollaries:

- **Put the drives in the new server, not `cellar`.** Under `host` domain, HDDs
  added to `cellar` contribute *zero* usable capacity, not merely zero
  redundancy. Only under `osd` domain does filling `cellar` help — another
  reason to run the crush rule dump before buying.
- **Home needs no storage changes.** `thing-0/1/2` hold 16.37 / 16.37 / 20.01
  TiB → ~16.4 TiB usable at `size=3`, inside the 10–20 TB target. Each `thing-*`
  has exactly one HDD (`osd.0`, `osd.2`, `osd.5`), so there are no spare drives to
  relocate; freeing capacity would mean emptying a host and dropping below three.

If the new hardware slips, the interim fallback is `size=2`/`min_size=2` at the
DC, which requires every node up — acceptable short-term, and reversible once the
third host lands.

### 4.2b The SSD pool break is real but low-stakes

`rama`, `thing-1` and `thunk-0` are the only SSD hosts, so the split leaves two
at the DC and one at home — below `size=3` on both sides. But `ssd-pool` holds
**803 MiB** against 5.4 TiB available, and SSD raw is 7% used. Rebuilding it on
either side is cheap. An earlier revision of this document called this the
sharpest finding; §4.2 is, by a wide margin.

### 4.3 Mon placement must move with the cluster

`ceph-mon=allowed` is labelled on `thing-0..4`, all of which stay home. Before
`thing-0/1/2` leave the cluster the label has to move to `cellar`, `rama` and
`thunk-0` so Rook can re-place the mon quorum. That is exactly three eligible
hosts, i.e. the minimum, with no spare.

### 4.4 Home cluster storage profile

The home cluster keeps three GPU nodes (`toothless`, `system3`, `grendal`) — none
of which carry OSDs — and ends up with 52.75 TiB HDD across `thing-0/1/2` plus a
single 3.73 TiB SSD. At `size=3` that is roughly 17.6 TiB usable HDD and **no
replicated SSD pool at all**. For an AI-agent workload, model storage would come
off HDD. Adding SSDs to `thing-0` and `thing-2` solves this and §4.2 together.

### 4.5 WAN exposure (assessed — low)

Home Assistant and its supporting services all land in the home cluster, so the
latency-sensitive paths stay on the LAN. The only cross-WAN access is the HA UI
from outside the network over Tailscale, which is fine. Worth re-checking the ~70
`kubeInternalEndpoints` once the per-cluster split is written down, to confirm
nothing latency-sensitive ends up on the wrong side.

### 4.6 Smaller items

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
