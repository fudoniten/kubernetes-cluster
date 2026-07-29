# Multi-cluster k3s NixOS module.
#
# Every host in a fleet evaluates the same set of cluster definitions; this
# module works out which one (if any) the host belongs to and configures it
# accordingly. Hosts named in no cluster get nothing.
#
# Submodules are imported as plain paths and each resolves its own context via
# `clusterLib.mkContext`. Do not go back to pre-applying arguments
# (`import ./k3s.nix { inherit config ...; }`): deriving the import list from
# `config` is what the module system cannot do, and it recurses.
{ config, lib, ... }:

with lib;

let
  clusterLib = import ../lib { inherit lib; };

  inherit (clusterLib.mkContext config)
    nodeName memberOf clusterName isMember cluster primaryIsNode isServer
    isPrimary isIngress isGpu;

in {
  imports = [
    ./options.nix
    ./k3s.nix
    ./dns.nix
    ./manifests.nix
    ./gateway.nix
    ./nvidia.nix
    ./storage.nix
  ];

  config = {
    # Always an attrset, on members and non-members alike; a non-member is
    # `cluster = null` with every boolean false. Do not "simplify" this to a
    # nullable attrset — that needs `nullOr (attrsOf anything)`, whose deep
    # merge over a value derived from the whole fleet is half of what 1c49db5
    # fixed. Consumers test `membership.cluster != null`.
    services.kubernetes-cluster.membership = {
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

    warnings = let
      serverCount = length (attrNames (clusterLib.serversOf cluster));
    in optional (isMember && (mod serverCount 2) == 0) ''
      Cluster '${toString clusterName}' has an even number of server nodes
      (${
        toString serverCount
      }). etcd needs an odd count to establish quorum.
    '';
  };
}
