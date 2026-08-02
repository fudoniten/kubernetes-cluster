# kubernetes-cluster

A NixOS module for running **several independent k3s clusters** from one shared
fleet configuration. Every host evaluates the same set of cluster definitions;
the module works out which cluster the host belongs to — if any — and configures
it accordingly.

It depends on nothing but `nixpkgs`. Node addresses and names are plain data, so
a configuration using it evaluates without any private inventory input.

See [`DESIGN.md`](./DESIGN.md) for the extraction and migration plan this was
built for.

## Usage

```nix
{
  inputs.kubernetes-cluster.url = "github:fudoniten/kubernetes-cluster";

  # ... in your NixOS modules:
  imports = [ inputs.kubernetes-cluster.nixosModules.default ];
}
```

```nix
services.kubernetes-cluster.clusters.home = {
  enable = true;
  tokenFile = "/run/k3s-secrets/token";
  tokenReadyUnits = [ "my-secrets.target" ];

  nodes = {
    kube-0 = {
      role = "server";
      address = "10.0.0.10";
      fqdn = "kube-0.example.com";
      ingress = true;
      labels = [ "storage=allowed" ];
    };
    kube-1 = {
      role = "agent";
      address = "10.0.0.11";
      fqdn = "kube-1.example.com";
      gpu.enable = true;
    };
  };

  storage.ceph.enable = true;

  gateway = {
    enable = true;
    host = "gateway";
    zone = "example.link";
    internalDomain = "example.com";
    externalHostname = "gateway.example.link";
  };

  endpoints.external = [{ name = "photos"; }];
};
```

## Concepts

**Node names.** `services.kubernetes-cluster.nodeName` identifies the host within
the `nodes` attrsets; it defaults to `networking.hostName`. Override it when the
NixOS hostname differs from the name used in your inventory.

**One cluster per host.** `services.k3s` is a NixOS singleton, so a host may
appear in at most one cluster's `nodes`. Listing it in two is an evaluation
error, not a runtime surprise. Defining clusters a host is *not* part of is
normal and expected — that is how a shared configuration describes a fleet.

**Primary master.** The node that runs `--cluster-init`; every other node joins
through its `address` unless `joinEndpoint` overrides that. It defaults to the
lexically first server rather than the first in some list, so adding an *agent*
cannot move it — but **promoting a node that sorts earlier will**, which puts
`--cluster-init` on the new node and repoints everyone's join address. Pin both
options explicitly on any cluster that is already running.

**Gateway.** Not gated on cluster membership — the gateway is frequently a host
outside the cluster it fronts. A single host can gateway several clusters; each
contributes its own virtual hosts and forwarded ports.

The gateway sets `networking.nat.forwardPorts` for TCP/UDP endpoints but
configures no NAT itself, since a gateway host has its own reasons to run it.
**The host owes `networking.nat.enable` and `networking.nat.externalInterface`**
— NixOS asserts on forwarded ports without an external interface. Likewise
`security.acme.acceptTerms` and a default email, if any external endpoint uses
the default `gateway.acme.enable = true`.

**Membership.** `services.kubernetes-cluster.membership` is a read-only summary
for consumers that need to derive their own configuration from the host's role:
`cluster`, `node`, `isServer`, `isPrimary`, `isIngress`, `isGpu`. On a
non-member, `membership.cluster` is `null` and the booleans are all `false` —
test the former rather than looking for an absent attrset.

## What this module does not do

It deliberately owns no naming, secrets or DNS policy. In particular:

- **It does not create the k3s token.** `tokenFile` is a path the module reads;
  put the token there yourself and name the responsible unit in
  `tokenReadyUnits` so k3s orders after it.
- **It does not publish DNS records.** It knows each node's `address` and
  `fqdn`, but emitting zone data is the consumer's business.
- **It does not carry a GPU label vocabulary.** `nvidia.deviceLabels` maps a
  normalised device model to whatever labels you want; the shipped tagger just
  applies them.

## Options

Everything hangs off `services.kubernetes-cluster.clusters.<name>`.

| Option | Default | Meaning |
|---|---|---|
| `enable` | `false` | Configure this cluster |
| `nodes.<name>.role` | `"agent"` | `server` runs the control plane |
| `nodes.<name>.address` | — | IPv4 address; required |
| `nodes.<name>.fqdn` | `null` | Used for TLS SANs and the tagger's API endpoint |
| `nodes.<name>.labels` / `.taints` | `[ ]` | `--node-label` / `--node-taint` |
| `nodes.<name>.ingress` | `false` | Adds the k3s service-LB label |
| `nodes.<name>.gpu.enable` | `false` | NVIDIA driver and CDI spec generation |
| `nodes.<name>.gpu.driverPackage` | `null` | Pin the driver branch for this node |
| `primaryMaster` | first server | Runs `--cluster-init`; pin it on a live cluster |
| `joinEndpoint` | primary's address | Stable host through which nodes join |
| `tokenFile` | — | Path to the join token; required |
| `tokenReadyUnits` | `[ ]` | Units k3s must start after |
| `apiPort` | `6443` | API server port |
| `tlsSans` | `[ ]` | Extra SANs beyond the servers' own FQDNs |
| `extraFlags` | `[ ]` | Extra k3s flags for all nodes |
| `nodePackages` | `[ ]` | Installed on every node |
| `serverPackages` | `[ kubectl kubernetes-helm ]` | Installed on servers |
| `dns.upstream` | `"1.1.1.1"` | CoreDNS forwarder |
| `dns.clusterDomain` | `"cluster.local"` | Internal DNS domain |
| `dns.corefile` | `null` | Replaces the generated Corefile |
| `manifests.<name>` | `{ }` | YAML applied by the primary master |
| `gateway.*` | — | See above |
| `endpoints.internal` / `.external` | `[ ]` | `{ name; type; port; }` |
| `storage.ceph.enable` | `false` | RBD modules and the `mount.ceph` helper |
| `nvidia.deviceLabels` | `{ }` | Device model → labels |
| `nvidia.baseLabels` | see source | Applied to every GPU node |
| `nvidia.tagger.*` | — | Token, CA cert and refresh interval |

> **GPU nodes.** `gpu.enable` installs the driver and the NVIDIA container
> toolkit, which generates CDI specs under `/var/run/cdi`. It deliberately does
> **not** configure containerd: k3s manages its own, and containerd reads CDI
> specs natively. Workloads get devices through the k8s device plugin running
> with a CDI device-list strategy — no `RuntimeClass` and no runtime wrapper.
>
> With `DEVICE_LIST_STRATEGY=cdi-cri` the plugin does not inject from that host
> spec — it generates its own from inside its container. The toolkit it vendors
> is stock upstream, so it looks for driver libraries only under FHS paths and
> lacks nixpkgs' dlopen discoverer. `gpu.enable` therefore also assembles a
> minimal FHS-shaped driver root at `/run/nvidia-driver-root`, which the plugin
> must mount at `/driver-root` while being pointed back at the host path with
> `NVIDIA_DRIVER_ROOT`. Set `NVIDIA_DEV_ROOT=/` alongside it: it defaults to
> `NVIDIA_DRIVER_ROOT`, which would otherwise rewrite every device node path.
> This is a contract with the plugin's internals rather than a documented
> interface — re-check it when bumping the image.
>
> An earlier revision ran a second containerd so the nvidia runtime could be
> configured by hand. That meant owning containerd's config schema, its sandbox
> image and its GC behaviour, and all three broke on a routine version bump, on
> GPU nodes only. If you need to influence k3s's containerd config, use its
> `config.toml.tmpl` hook rather than running a second daemon.
>
> `gpu.driverPackage` is per-node because the driver is system-wide and follows
> the hardware. NVIDIA's 580 branch is the last supporting Maxwell, Pascal and
> Volta, so a node with a P40, P4, Quadro P-series or V100 needs pinning to it.
> Newer drivers do not fail loudly on such a card — they enumerate it, log that
> they are ignoring it, and leave NVML reporting `Driver Not Loaded`, which
> surfaces as CDI spec generation failing rather than as a driver error.

## Tests

```bash
nix flake check
```

- **`checks.eval`** builds NixOS configurations for a two-cluster fleet and
  asserts the derived roles, join addresses, flags and membership. Pure eval,
  runs anywhere, seconds. This is the check that catches mis-plumbed options.
- **`checks.two-clusters`** boots three VMs forming two real k3s clusters and
  asserts that neither sees the other's nodes. Needs KVM and a few minutes.

The fleet both tests share lives in [`tests/fleet.nix`](./tests/fleet.nix).
