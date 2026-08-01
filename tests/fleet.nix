# A small two-cluster fleet, shared by the eval and VM tests.
#
# Every host evaluates this same definition; the module works out which cluster
# each belongs to. `gw` is deliberately not a member of either cluster, to
# exercise a gateway that lives outside the clusters it fronts.
{
  services.kubernetes-cluster.clusters = {
    alpha = {
      enable = true;
      tokenFile = "/run/alpha/token";
      tokenReadyUnits = [ "alpha-secrets.target" ];

      nodes = {
        a0 = {
          role = "server";
          address = "192.168.1.10";
          fqdn = "a0.alpha.example.com";
          ingress = true;
          labels = [ "tier=control" ];
        };
        a1 = {
          role = "agent";
          address = "192.168.1.11";
          fqdn = "a1.alpha.example.com";
          gpu.enable = true;
          taints = [ "dedicated=gpu:NoSchedule" ];
        };
      };

      storage.ceph.enable = true;

      nvidia = {
        deviceLabels."tesla-t4" = [ "example.com/gpu.model-tesla-t4" ];
        tagger.tokenFile = "/run/alpha/tagger-token";
      };

      gateway = {
        enable = true;
        host = "gw";
        zone = "alpha.example.com";
        internalDomain = "internal.example.com";
        externalHostname = "gw.example.com";
      };

      endpoints = {
        internal = [{ name = "dash"; }];
        external = [
          { name = "api"; }
          {
            name = "stream";
            type = "TCP";
            port = 9000;
          }
        ];
      };
    };

    beta = {
      enable = true;
      tokenFile = "/run/beta/token";

      # Overrides the default of the primary master's address, so replacing b0
      # does not strand a rebuilt node. Alpha deliberately leaves this unset so
      # both paths are covered.
      joinEndpoint = "kube.beta.example.com";

      nodes = {
        b0 = {
          role = "server";
          address = "192.168.2.10";
          fqdn = "b0.beta.example.com";
        };
        b1 = {
          role = "server";
          address = "192.168.2.11";
          fqdn = "b1.beta.example.com";
        };
        b2 = {
          role = "server";
          address = "192.168.2.12";
          fqdn = "b2.beta.example.com";
        };
      };

      # Same gateway host as alpha, on purpose: the gateway has to merge
      # contributions from every cluster it fronts.
      gateway = {
        enable = true;
        host = "gw";
        zone = "beta.example.com";
        internalDomain = "internal.example.com";
        externalHostname = "gw.example.com";
      };

      endpoints.external = [{ name = "beta-api"; }];
    };
  };
}
