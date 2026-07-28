# Multi-cluster k3s NixOS module.
#
# Every host in a fleet evaluates the same set of cluster definitions; this
# module works out which one (if any) the host belongs to and configures it
# accordingly. Hosts named in no cluster get nothing.
{ config, lib, pkgs, ... }:

with lib;

let
  clusterLib = import ../lib { inherit lib; };

  cfg = config.services.kubernetes-cluster;

  nodeName = cfg.nodeName;

  # Clusters claiming this host. More than one is rejected below; taking the
  # head keeps the rest of the evaluation total in the presence of that error,
  # so the assertion is what the user sees rather than a stray attribute error.
  memberOf = clusterLib.clustersFor nodeName cfg.clusters;
  clusterName = if memberOf == [ ] then null else head memberOf;
  isMember = clusterName != null;

  # Placeholder cluster/node for non-members. Nothing reads these — every
  # submodule guards on `isMember` — but they keep option access total.
  cluster = if isMember then cfg.clusters.${clusterName} else null;
  node = if isMember then cluster.nodes.${nodeName} else null;

  isServer = isMember && node.role == "server";
  isPrimary = isMember && cluster.primaryMaster == nodeName;
  isIngress = isMember && node.ingress;
  isGpu = isMember && node.gpu.enable;

  primaryIsNode = isMember && (cluster.nodes ? ${cluster.primaryMaster});

  # Address the rest of the cluster joins through.
  primaryAddress = if isMember && cluster.nodes ? ${cluster.primaryMaster} then
    cluster.nodes.${cluster.primaryMaster}.address
  else
    null;

  ctx = {
    inherit config lib pkgs clusterLib cfg nodeName clusterName cluster node
      isMember isServer isPrimary isIngress isGpu primaryAddress;
  };

in {
  imports = [
    (import ./options.nix { inherit config lib pkgs clusterLib; })
    (import ./k3s.nix ctx)
    (import ./dns.nix ctx)
    (import ./manifests.nix ctx)
    (import ./gateway.nix ctx)
    (import ./nvidia.nix ctx)
    (import ./storage.nix ctx)
  ];

  config = {
    services.kubernetes-cluster.membership = mkIf isMember {
      cluster = clusterName;
      node = nodeName;
      inherit isServer isPrimary isIngress isGpu;
    };

    assertions = [
      {
        # services.k3s is a singleton: a host cannot run two clusters.
        assertion = (length memberOf) <= 1;
        message = ''
          Host '${nodeName}' is claimed by multiple Kubernetes clusters
          (${
            concatStringsSep ", " memberOf
          }). A host may belong to at most one, since services.k3s is a
          singleton. Remove it from all but one cluster's `nodes`.
        '';
      }
      {
        assertion = !isMember || cluster.primaryMaster != "";
        message = ''
          Cluster '${toString clusterName}' has no primaryMaster and no server
          nodes to default to. At least one node must have `role = "server"`.
        '';
      }
      {
        assertion = !isMember || primaryIsNode;
        message = ''
          Cluster '${toString clusterName}' sets primaryMaster to
          '${cluster.primaryMaster}', which is not one of its nodes.
        '';
      }
      {
        # Guarded on primaryIsNode so a bad name reports as the assertion above
        # rather than throwing on the attribute access.
        assertion = !isMember || !primaryIsNode
          || cluster.nodes.${cluster.primaryMaster}.role == "server";
        message = ''
          Cluster '${toString clusterName}' sets primaryMaster to
          '${cluster.primaryMaster}', whose role is "agent". The primary master
          must be a server.
        '';
      }
      {
        assertion = !isGpu || !cluster.nvidia.tagger.enable
          || cluster.nvidia.tagger.tokenFile != null;
        message = ''
          Node '${nodeName}' enables GPU support and cluster
          '${toString clusterName}' enables the GPU tagger, but
          `nvidia.tagger.tokenFile` is unset.
        '';
      }
    ] ++ (optionals isMember (map (ep: {
      assertion = ep.type == "HTTP" || ep.port != null;
      message = ''
        Endpoint '${ep.name}' in cluster '${toString clusterName}' is of type
        ${ep.type} and must set `port`.
      '';
    }) (cluster.endpoints.internal ++ cluster.endpoints.external)));

    warnings = optional (isMember && (mod (length (attrNames
      (clusterLib.serversOf cluster))) 2) == 0) ''
        Cluster '${toString clusterName}' has an even number of server nodes
        (${
          toString (length (attrNames (clusterLib.serversOf cluster)))
        }). etcd needs an odd count to establish quorum.
      '';
  };
}
