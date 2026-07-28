# Cluster DNS: a CoreDNS ConfigMap dropped in as a k3s custom manifest.
{ lib, cluster, isMember, ... }:

with lib;

let
  defaultCorefile = ''
    .:53 {
      errors
      health {
        lameduck 5s
      }
      ready
      kubernetes ${cluster.dns.clusterDomain} in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
        ttl 30
      }
      prometheus :9153
      forward . ${cluster.dns.upstream}
      cache 30
      loop
      reload
      loadbalance
    }
  '';

in {
  config = mkIf isMember {
    environment.etc."k3s/coredns.custom.yaml" = {
      mode = "0750";
      text = builtins.toJSON {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata = {
          name = "coredns";
          namespace = "kube-system";
        };
        data.Corefile = if cluster.dns.corefile != null then
          cluster.dns.corefile
        else
          defaultCorefile;
      };
    };
  };
}
