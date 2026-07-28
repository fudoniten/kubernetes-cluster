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
  stateDirectory = "/state/services/kubernetes";
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
through its `address`. Defaults to the lexically first server rather than the
first in some list, so that adding an unrelated node cannot silently move it.

**Gateway.** Not gated on cluster membership — the gateway is frequently a host
outside the cluster it fronts. A single host can gateway several clusters; each
contributes its own virtual hosts and forwarded ports.

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
| `nodes.<name>.gpu.enable` | `false` | NVIDIA containerd/CDI stack |
| `primaryMaster` | first server | Runs `--cluster-init` |
| `tokenFile` | — | Path to the join token; required |
| `tokenReadyUnits` | `[ ]` | Units k3s must start after |
| `stateDirectory` | — | See the caveat below |
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

> **`stateDirectory` caveat.** It currently only relocates containerd's root and
> state directories on GPU nodes. k3s itself keeps its data in
> `/var/lib/rancher/k3s`. This mirrors the behaviour of the module this was
> extracted from; it is a wart, preserved deliberately so the extraction is a
> no-op, and worth fixing separately.

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
