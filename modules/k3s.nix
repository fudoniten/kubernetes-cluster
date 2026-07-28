# Core k3s service: cluster init, joining, roles, labels and shutdown ordering.
{ config, lib, pkgs, ... }:

with lib;

let
  clusterLib = import ../lib { inherit lib; };

  inherit (clusterLib.mkContext config)
    cluster node isMember isServer isPrimary isIngress isGpu primaryAddress;

in {
  config = mkIf isMember {
    networking = {
      useHostResolvConf = true;
      # Cluster networking (CNI, service proxying, node-to-node) assumes an
      # unfiltered path between nodes.
      firewall.enable = false;
    };

    systemd = {
      services.k3s = {
        restartIfChanged = true;

        serviceConfig = {
          # Give storage backends time to shut down cleanly.
          TimeoutStopSec = "30s";
        };

        requires = cluster.tokenReadyUnits;
        after = cluster.tokenReadyUnits;

        # k3s must stop before filesystems go away. Ordering relative to the
        # network is implicit: After=network-online.target means k3s stops
        # before network-online.target, which stops before network.target.
        before = [ "umount.target" ]
          ++ (optional cluster.storage.ceph.enable "ceph-mount.service");

        # Begin shutting k3s down as soon as shutdown starts, rather than
        # waiting for the ordinary teardown ordering to reach it.
        conflicts = [ "shutdown.target" ];
        wantedBy = [ "multi-user.target" ];
        unitConfig = { DefaultDependencies = false; };
      };

      tmpfiles.settings."040-kubernetes"."/etc/rancher/k3s/k3s.yaml".z = {
        mode = "0640";
        user = "root";
        group = "k3s";
      };
    };

    environment = {
      shellInit = ''
        if [[ "root" == "$USER" ]]; then
          export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        fi
      '';

      systemPackages = (optionals isServer cluster.serverPackages)
        ++ cluster.nodePackages;
    };

    services.k3s = {
      enable = true;
      role = if isServer then "server" else "agent";
      serverAddr = mkIf (!isPrimary)
        "https://${primaryAddress}:${toString cluster.apiPort}";
      clusterInit = isPrimary;
      tokenFile = cluster.tokenFile;
      gracefulNodeShutdown.enable = true;

      extraFlags = let
        # Servers terminate TLS for the API; the certificate has to cover every
        # name a client might use to reach them.
        serverFqdns = filter (fqdn: fqdn != null)
          (mapAttrsToList (_: n: n.fqdn) (clusterLib.serversOf cluster));
        # Explicit SANs first, derived ones after, so a consumer can pin the
        # exact flag order it emitted before adopting this module.
        sanFlags = optionals isServer
          (map (san: "--tls-san=${san}") (unique (cluster.tlsSans ++ serverFqdns)));

        # GPU base labels are applied here rather than written back into
        # `node.labels`, which a module cannot define without a cycle.
        labels = node.labels ++ (optionals isGpu cluster.nvidia.baseLabels)
          ++ (optional isIngress "svccontroller.k3s.cattle.io/enablelb=true");
        labelFlags = map (label: "--node-label=${label}") labels;
        taintFlags = map (taint: "--node-taint=${taint}") node.taints;

      in sanFlags ++ labelFlags ++ taintFlags ++ cluster.extraFlags
      ++ node.extraFlags;
    };
  };
}
