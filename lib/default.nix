# Pure helpers over cluster definitions. No NixOS config is touched here, so
# these are safe to use from consumers at eval time.
{ lib }:

with lib;

rec {
  serversOf = cluster: filterAttrs (_: node: node.role == "server") cluster.nodes;

  agentsOf = cluster: filterAttrs (_: node: node.role == "agent") cluster.nodes;

  ingressNodesOf = cluster: filterAttrs (_: node: node.ingress) cluster.nodes;

  gpuNodesOf = cluster: filterAttrs (_: node: node.gpu.enable) cluster.nodes;

  # The node which runs `--cluster-init`. Lexically first server rather than
  # `head` over a user-ordered list: attrsets have no meaningful order, and a
  # primary master that moves when an unrelated node is added would re-init the
  # cluster.
  defaultPrimaryMaster = cluster:
    let servers = sort lessThan (attrNames (serversOf cluster));
    in if servers == [ ] then "" else head servers;

  # Names of enabled clusters which list `nodeName` among their nodes. More than
  # one is a configuration error (see the assertions in modules/default.nix);
  # returning the full list lets that error name every offender.
  clustersFor = nodeName: clusters:
    attrNames
    (filterAttrs (_: cluster: cluster.enable && hasAttr nodeName cluster.nodes)
      clusters);

  # Resolves a host's place in the fleet from the NixOS config.
  #
  # Every submodule calls this rather than having a context threaded into it by
  # the entry module: computing `imports` from `config` is the classic route to
  # an infinite recursion, so each module here is a plain NixOS module that
  # reads config itself.
  mkContext = config:
    let
      cfg = config.services.kubernetes-cluster;
      nodeName = cfg.nodeName;

      # Clusters claiming this host. More than one is rejected by an assertion
      # in modules/default.nix; taking the head keeps evaluation total in the
      # presence of that error, so the assertion is what the user sees rather
      # than a stray attribute error.
      memberOf = clustersFor nodeName cfg.clusters;
      clusterName = if memberOf == [ ] then null else head memberOf;
      isMember = clusterName != null;

      # Null for non-members. Nothing reads these — every submodule guards on
      # `isMember` — but they keep option access total.
      cluster = if isMember then cfg.clusters.${clusterName} else null;
      node = if isMember then cluster.nodes.${nodeName} else null;

      primaryIsNode = isMember && (cluster.nodes ? ${cluster.primaryMaster});

    in {
      inherit cfg nodeName memberOf clusterName isMember cluster node
        primaryIsNode;

      isServer = isMember && node.role == "server";
      isPrimary = isMember && cluster.primaryMaster == nodeName;
      isIngress = isMember && node.ingress;
      isGpu = isMember && node.gpu.enable;

      # Address through which the rest of the cluster joins.
      primaryAddress = if primaryIsNode then
        cluster.nodes.${cluster.primaryMaster}.address
      else
        null;
    };

  # Endpoints reachable over plain HTTP(S), i.e. the ones the gateway proxies.
  httpEndpoints = endpoints: filter (ep: ep.type == "HTTP") endpoints;

  # Endpoints which need a forwarded port rather than a virtual host.
  streamEndpoints = endpoints:
    filter (ep: ep.type == "TCP" || ep.type == "UDP") endpoints;
}
