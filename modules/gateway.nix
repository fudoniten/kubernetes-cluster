# Cluster gateway: nginx virtual hosts for HTTP endpoints, NAT forwarding for
# TCP/UDP ones.
#
# Unlike the other submodules this is not gated on cluster membership: the
# gateway is frequently a host outside the cluster. A single host may gateway
# several clusters, so every matching cluster contributes.
{ config, lib, ... }:

with lib;

let
  clusterLib = import ../lib { inherit lib; };

  inherit (clusterLib.mkContext config) cfg nodeName;

  gatewayedClusters = filterAttrs (_: cluster:
    cluster.enable && cluster.gateway.enable && cluster.gateway.host == nodeName)
    cfg.clusters;

  isGateway = gatewayedClusters != { };

  eachCluster = f: map f (attrValues gatewayedClusters);

  virtualHostsFor = cluster:
    let
      inherit (cluster.gateway) zone internalDomain;

      externalHttp = clusterLib.httpEndpoints cluster.endpoints.external;
      internalHttp = clusterLib.httpEndpoints cluster.endpoints.internal;

      # Public names, terminating TLS and proxying into the cluster ingress.
      externalHosts = listToAttrs (map ({ name, ... }:
        nameValuePair "${name}.${zone}" {
          forceSSL = cluster.gateway.acme.enable;
          enableACME = cluster.gateway.acme.enable;
          locations."/" = {
            proxyPass = "https://${name}.kube.${zone}/";
            proxyWebsockets = true;
            recommendedProxySettings = true;
          };
        }) externalHttp);

      # Internal names, redirecting to the canonical public endpoint.
      internalHosts = listToAttrs (map ({ name, ... }:
        nameValuePair "${name}.${internalDomain}" {
          locations."/".return = "301 https://${name}.kube.${zone}/";
        }) (externalHttp ++ internalHttp));

    in externalHosts // internalHosts;

  portsOfType = type: cluster:
    map ({ port, ... }: port)
    (filter (endpoint: endpoint.type == type) cluster.endpoints.external);

  forwardPortsFor = cluster:
    let ingressPoint = cluster.nodes.${cluster.primaryMaster}.address;
    in map ({ type, port, ... }: {
      destination = "${ingressPoint}:${toString port}";
      proto = if type == "TCP" then "tcp" else "udp";
      sourcePort = port;
    }) (clusterLib.streamEndpoints cluster.endpoints.external);

  mergeAll = f: foldl' (acc: cluster: acc // f cluster) { }
    (attrValues gatewayedClusters);

  concatAll = f: concatLists (eachCluster f);

in {
  # The attribute *shape* below must be knowable without reading `config`.
  #
  # The module system walks every module's `config` to collect option
  # definitions before any option value exists, and `pushDownProperties` forces
  # a `mkMerge`'s content list during that walk. An earlier revision built the
  # merge list from `cfg.clusters`:
  #
  #     config = mkMerge (mapAttrsToList (_: gatewayConfig) gatewayedClusters);
  #
  # which made definition collection depend on the merged value of the very
  # option being collected — an infinite recursion, and one that only this
  # module hit, because the others are `mkIf isMember { ...static attrs... }`.
  #
  # `mkIf` is safe in the same position: its condition is re-wrapped rather
  # than forced during the walk. So conditions and leaf option *values* may
  # read `config` freely; attribute names may not.
  config = {
    services.nginx = mkIf isGateway {
      enable = true;
      recommendedProxySettings = true;
      recommendedOptimisation = true;
      recommendedGzipSettings = true;
      recommendedTlsSettings = true;
      virtualHosts = mergeAll virtualHostsFor;
    };

    networking = {
      firewall = {
        allowedTCPPorts = mkIf isGateway (concatAll (portsOfType "TCP"));
        allowedUDPPorts = mkIf isGateway (concatAll (portsOfType "UDP"));
      };

      nat.forwardPorts = mkIf isGateway (concatAll forwardPortsFor);
    };
  };
}
