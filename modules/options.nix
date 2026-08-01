# Option declarations for services.kubernetes-cluster.
{ config, lib, pkgs, ... }:

with lib;

let
  clusterLib = import ../lib { inherit lib; };

  endpointType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Endpoint hostname, relative to the cluster zone.";
      };

      type = mkOption {
        type = types.enum [ "HTTP" "TCP" "UDP" ];
        default = "HTTP";
        description = ''
          HTTP endpoints are proxied by the gateway as virtual hosts. TCP and
          UDP endpoints are forwarded by port, and must set `port`.
        '';
      };

      port = mkOption {
        type = types.nullOr types.port;
        default = null;
        description = "Port this endpoint listens on. Required for TCP/UDP.";
      };
    };
  };

  nodeType = types.submodule {
    options = {
      role = mkOption {
        type = types.enum [ "server" "agent" ];
        default = "agent";
        description = ''
          `server` runs the control plane (k3s server); `agent` runs workloads
          only. Servers also run workloads.
        '';
      };

      address = mkOption {
        type = types.str;
        description = ''
          IPv4 address of this node. Used by agents to reach the primary
          server, and to generate ingress records.
        '';
      };

      fqdn = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Fully-qualified domain name of this node, if it has one. Used for
          TLS SANs on servers and as the API endpoint for the GPU tagger.
        '';
      };

      labels = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "ceph-mon=allowed" "workload=batch" ];
        description = "Node labels, passed to k3s as `--node-label`.";
      };

      taints = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "dedicated=gpu:NoSchedule" ];
        description = "Node taints, passed to k3s as `--node-taint`.";
      };

      ingress = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether this node participates in service load balancing. Adds the
          `svccontroller.k3s.cattle.io/enablelb` label.
        '';
      };

      gpu.enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable the NVIDIA containerd/CDI stack on this node. See the
          cluster-level `nvidia` options for the shared configuration.
        '';
      };

      extraFlags = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Additional k3s flags for this node alone.";
      };
    };
  };

  clusterType = types.submodule ({ name, config, ... }: {
    options = {
      enable = mkEnableOption "the ${name} Kubernetes cluster";

      verbose = mkEnableOption "verbose output from cluster helper services";

      nodes = mkOption {
        type = types.attrsOf nodeType;
        default = { };
        description = ''
          Every node in this cluster, keyed by node name. A node name must
          match `services.kubernetes-cluster.nodeName` on the corresponding
          host for that host to configure itself as a member.
        '';
      };

      primaryMaster = mkOption {
        type = types.str;
        default = clusterLib.defaultPrimaryMaster config;
        defaultText = literalExpression "the lexically first server node";
        description = ''
          Node which initialises the cluster (`--cluster-init`). Other servers
          and all agents join through it, unless `joinEndpoint` says otherwise.

          **Pin this explicitly on a running cluster.** The default is stable
          against adding *agents*, but promoting a node whose name sorts
          earlier moves it — which would put `--cluster-init` on the new node
          and repoint every other node's join address.
        '';
      };

      joinEndpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
        defaultText = literalExpression "the primary master's address";
        example = "kube.example.com";
        description = ''
          Host or address through which nodes join, without scheme or port.
          Defaults to the primary master's `address`.

          Pin this to something stable — a VIP, or a name covering every server
          — when the primary master may be replaced. A node that has already
          joined caches cluster membership and is unaffected, but one rebuilt
          or rebooted after the primary is gone needs an endpoint that still
          resolves.
        '';
      };

      apiPort = mkOption {
        type = types.port;
        default = 6443;
        description = "Port on which the Kubernetes API server listens.";
      };

      tokenFile = mkOption {
        type = types.str;
        description = ''
          Path on the node to the file holding the k3s cluster join token. This
          module does not create it; see `tokenReadyUnits` for ordering against
          whatever does.
        '';
      };

      tokenReadyUnits = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "fudo-secrets.target" ];
        description = ''
          Systemd units which must be active before k3s starts, i.e. whatever
          places `tokenFile` on disk. Added to both `requires` and `after`.
        '';
      };

      tlsSans = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Extra TLS subject alternative names for the API server certificate,
          in addition to the FQDNs of the cluster's own server nodes.
        '';
      };

      extraFlags = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Additional k3s flags applied to every node.";
      };

      nodePackages = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = "Packages installed on every node in this cluster.";
      };

      serverPackages = mkOption {
        type = types.listOf types.package;
        default = with pkgs; [ kubectl kubernetes-helm ];
        defaultText = literalExpression "with pkgs; [ kubectl kubernetes-helm ]";
        description = "Packages installed on server nodes, in addition to `nodePackages`.";
      };

      dns = {
        upstream = mkOption {
          type = types.str;
          default = "1.1.1.1";
          description = ''
            DNS server to which CoreDNS forwards queries for names outside the
            cluster.
          '';
        };

        clusterDomain = mkOption {
          type = types.str;
          default = "cluster.local";
          description = "Internal DNS domain for cluster services.";
        };

        corefile = mkOption {
          type = types.nullOr types.lines;
          default = null;
          description = ''
            Replaces the generated Corefile wholesale. An escape hatch; when
            null a Corefile is built from the other `dns` options.
          '';
        };
      };

      manifests = mkOption {
        type = types.attrsOf types.lines;
        default = { };
        example = literalExpression ''{ "flux-namespace" = "..."; }'';
        description = ''
          YAML documents written to `/etc/k3s` and applied by the primary
          master once k3s is up. Keys name the file; `.yaml` is appended.
        '';
      };

      gateway = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Configure this cluster's gateway. Takes effect only on the host
            named by `gateway.host`.
          '';
        };

        host = mkOption {
          type = types.str;
          default = "";
          description = ''
            Name of the gateway host, matched against `nodeName`. Need not be
            a cluster node.
          '';
        };

        externalHostname = mkOption {
          type = types.str;
          default = "";
          description = "FQDN by which the gateway is reachable externally.";
        };

        zone = mkOption {
          type = types.str;
          default = "";
          description = ''
            Public DNS zone under which endpoints are published. Endpoints are
            served at `<name>.<zone>` and proxied to `<name>.kube.<zone>`.
          '';
        };

        internalDomain = mkOption {
          type = types.str;
          default = "";
          description = ''
            Internal domain of the gateway host. Requests to
            `<name>.<internalDomain>` are redirected to the public endpoint.
          '';
        };

        acme.enable = mkOption {
          type = types.bool;
          default = true;
          description = "Terminate TLS with ACME certificates on the gateway.";
        };
      };

      endpoints = {
        internal = mkOption {
          type = types.listOf endpointType;
          default = [ ];
          description = "Endpoints reachable only from inside the network.";
        };

        external = mkOption {
          type = types.listOf endpointType;
          default = [ ];
          description = "Endpoints reachable from outside the network.";
        };
      };

      storage.ceph.enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Load the Ceph RBD kernel modules and expose the `mount.ceph` helper
          where k3s can find it, for hosts backing Ceph-provisioned volumes.
        '';
      };

      nvidia = {
        deviceLabels = mkOption {
          type = types.attrsOf (types.listOf types.str);
          default = { };
          example = literalExpression ''
            { "tesla-t4" = [ "gpu.model-tesla-t4" "gpu.mem-midmem" ]; }
          '';
          description = ''
            Map of normalised GPU model name to the labels applied to nodes
            carrying that device. Consumed by the tagger.
          '';
        };

        baseLabels = mkOption {
          type = types.listOf types.str;
          default = [
            "nvidia.com/gpu.present=true"
            "nixos-nvidia-cdi=enabled"
            "gpu=enabled"
          ];
          description = "Labels applied to every GPU node regardless of model.";
        };

        tagger = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Periodically label GPU nodes according to the devices they carry.
            '';
          };

          tokenFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Path on the node to the tagger's Kubernetes bearer token.
            '';
          };

          caCertFile = mkOption {
            type = types.str;
            default = "/var/lib/rancher/k3s/agent/server-ca.crt";
            description = ''
              CA certificate used to verify the Kubernetes API server.
            '';
          };

          interval = mkOption {
            type = types.str;
            default = "1h";
            description = "How often to refresh GPU node labels.";
          };
        };
      };
    };
  });

in {
  options.services.kubernetes-cluster = {
    nodeName = mkOption {
      type = types.str;
      default = config.networking.hostName;
      defaultText = literalExpression "config.networking.hostName";
      description = ''
        Name identifying this host within cluster node sets. Override when the
        NixOS hostname differs from the name used in inventory.
      '';
    };

    clusters = mkOption {
      type = types.attrsOf clusterType;
      default = { };
      description = ''
        Named clusters. A host may belong to at most one, since `services.k3s`
        is a singleton; defining clusters a host is not part of is harmless and
        is how a shared configuration describes a whole fleet.
      '';
    };

    # Read-only summary of this host's role, for consumers that need to derive
    # their own configuration from it. Declared as an option group rather than
    # one option holding a freeform attrset: `attrsOf anything` merges deeply,
    # which puts evaluation pressure on a value derived from every cluster
    # definition in the fleet.
    membership = {
      cluster = mkOption {
        type = types.nullOr types.str;
        readOnly = true;
        description = ''
          Name of the cluster this host belongs to, or null if it belongs to
          none. Consumers should test this rather than looking for an absent
          attrset.
        '';
      };

      node = mkOption {
        type = types.str;
        readOnly = true;
        description = "This host's node name.";
      };

      isServer = mkOption {
        type = types.bool;
        readOnly = true;
        description = "Whether this host runs the control plane.";
      };

      isPrimary = mkOption {
        type = types.bool;
        readOnly = true;
        description = "Whether this host initialises its cluster.";
      };

      isIngress = mkOption {
        type = types.bool;
        readOnly = true;
        description = "Whether this host participates in load balancing.";
      };

      isGpu = mkOption {
        type = types.bool;
        readOnly = true;
        description = "Whether this host runs the NVIDIA stack.";
      };
    };
  };
}
