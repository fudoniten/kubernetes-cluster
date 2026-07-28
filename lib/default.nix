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

  # Endpoints reachable over plain HTTP(S), i.e. the ones the gateway proxies.
  httpEndpoints = endpoints: filter (ep: ep.type == "HTTP") endpoints;

  # Endpoints which need a forwarded port rather than a virtual host.
  streamEndpoints = endpoints:
    filter (ep: ep.type == "TCP" || ep.type == "UDP") endpoints;
}
