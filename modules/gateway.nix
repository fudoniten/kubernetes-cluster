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

  gatewayedClusters = filterAttrs
    (_: cluster: cluster.enable && cluster.gateway.enable && cluster.gateway.host == nodeName)
    cfg.clusters;

  gatewayConfig = cluster:
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

      streamEndpoints = clusterLib.streamEndpoints cluster.endpoints.external;

      ingressPoint = cluster.nodes.${cluster.primaryMaster}.address;

    in {
      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        recommendedOptimisation = true;
        recommendedGzipSettings = true;
        recommendedTlsSettings = true;
        virtualHosts = externalHosts // internalHosts;
      };

      networking = {
        firewall = {
          allowedTCPPorts = map ({ port, ... }: port)
            (filter ({ type, ... }: type == "TCP") cluster.endpoints.external);
          allowedUDPPorts = map ({ port, ... }: port)
            (filter ({ type, ... }: type == "UDP") cluster.endpoints.external);
        };

        nat.forwardPorts = map ({ type, port, ... }: {
          destination = "${ingressPoint}:${toString port}";
          proto = if type == "TCP" then "tcp" else "udp";
          sourcePort = port;
        }) streamEndpoints;
      };
    };

in {
  config = mkMerge (mapAttrsToList (_: gatewayConfig) gatewayedClusters);
}
