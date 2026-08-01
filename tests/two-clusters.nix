# Two independent k3s clusters built from one shared fleet definition, on
# three VMs. This is the test that justifies the refactor: it proves a single
# set of cluster definitions produces separate clusters that do not see each
# other, rather than one cluster with confused membership.
{ module }:

{ lib, pkgs, ... }:

let
  token = "hunter2hunter2hunter2hunter2hunt";

  # Disable the addons that need to pull images or bind host ports; the point
  # here is cluster formation and separation, not a working ingress.
  leanFlags = [
    "--disable=coredns"
    "--disable=local-storage"
    "--disable=metrics-server"
    "--disable=servicelb"
    "--disable=traefik"
  ];

  fleet = {
    services.kubernetes-cluster.clusters = {
      alpha = {
        enable = true;
        tokenFile = "/etc/k3s-token";
        extraFlags = leanFlags;
        nodes = {
          a0 = {
            role = "server";
            address = "192.168.1.1";
            ingress = true;
          };
          a1 = {
            role = "agent";
            address = "192.168.1.2";
            labels = [ "tier=worker" ];
          };
        };
      };

      beta = {
        enable = true;
        tokenFile = "/etc/k3s-token";
        extraFlags = leanFlags;
        nodes.b0 = {
          role = "server";
          address = "192.168.1.3";
        };
      };
    };
  };

  common = {
    imports = [ module fleet ];

    environment.etc."k3s-token".text = token;

    virtualisation = {
      memorySize = 2048;
      diskSize = 6144;
      cores = 2;
    };

    # k3s has no network in the test VMs, so preload the images it would
    # otherwise pull.
    systemd.services.k3s = {
      path = [ pkgs.gzip ];
      preStart = ''
        mkdir -p /var/lib/rancher/k3s/agent/images/
        ln -sf ${pkgs.k3s.airgap-images} \
          /var/lib/rancher/k3s/agent/images/airgap-images.tar.zst
      '';
    };
  };

in {
  name = "kubernetes-cluster-two-clusters";

  nodes = {
    a0 = common;
    a1 = common;
    b0 = common;
  };

  testScript = ''
    start_all()

    with subtest("both control planes come up"):
        a0.wait_for_unit("k3s.service")
        b0.wait_for_unit("k3s.service")
        a0.wait_until_succeeds("k3s kubectl get node a0 | grep -w Ready", timeout=300)
        b0.wait_until_succeeds("k3s kubectl get node b0 | grep -w Ready", timeout=300)

    with subtest("the agent joins its own cluster"):
        a1.wait_for_unit("k3s.service")
        a0.wait_until_succeeds("k3s kubectl get node a1 | grep -w Ready", timeout=300)
        a0.succeed("k3s kubectl get node a1 -o jsonpath='{.metadata.labels.tier}' | grep -w worker")

    with subtest("the ingress node is labelled"):
        a0.succeed(
            "k3s kubectl get node a0 -o jsonpath="
            "'{.metadata.labels.svccontroller\\.k3s\\.cattle\\.io/enablelb}' | grep -w true"
        )

    with subtest("the clusters are separate"):
        a0.fail("k3s kubectl get node b0")
        b0.fail("k3s kubectl get node a0")
        b0.fail("k3s kubectl get node a1")
        b0.succeed("test $(k3s kubectl get nodes --no-headers | wc -l) -eq 1")
        a0.succeed("test $(k3s kubectl get nodes --no-headers | wc -l) -eq 2")
  '';
}
