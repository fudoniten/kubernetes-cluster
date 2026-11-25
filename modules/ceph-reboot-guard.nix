# Ceph-safe reboots: pin a Rook cluster's data in place while a node is down,
# and release the pins once it is back. See `storage.ceph.rebootGuard` in
# options.nix for the behaviour, and static/ceph-reboot-guard.sh for the logic.
{ config, lib, pkgs, ... }:

with lib;

let
  inherit (import ../lib { inherit lib; }) mkContext;
  inherit (mkContext config) cluster nodeName isMember isServer;

  guard = if isMember then cluster.storage.ceph.rebootGuard else null;

  configured = isMember && cluster.storage.ceph.enable && guard.enable;

  # Servers fall back on the k3s admin kubeconfig; an agent has nothing to
  # authenticate with unless it is given a token.
  hasCredentials = isServer || guard.tokenFile != null;

  active = configured && hasCredentials;

  systemdBin = "${config.systemd.package}/bin";

  # config-key prefix under which each rebooting node leaves a marker. The
  # flags are cluster-wide; the markers are how one node's recovery knows
  # another node is still mid-reboot.
  markerPrefix = "kubernetes-cluster/reboot-guard/";

  ceph-reboot-guard = pkgs.writeShellApplication {
    name = "ceph-reboot-guard";
    runtimeInputs = with pkgs; [ kubectl jq coreutils gnugrep config.systemd.package ];
    text = ''
      GUARD_NODE=${escapeShellArg nodeName}
      GUARD_NAMESPACE=${escapeShellArg guard.namespace}
      GUARD_TOOLS_DEPLOYMENT=${escapeShellArg guard.toolsDeployment}
      GUARD_TOKEN_FILE=${escapeShellArg (if guard.tokenFile == null then "" else guard.tokenFile)}
      GUARD_CA_FILE=${escapeShellArg guard.caCertFile}
      GUARD_API_SERVER=${escapeShellArg guard.apiServer}
      GUARD_ADMIN_KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      GUARD_MARKER_PREFIX=${escapeShellArg markerPrefix}
      GUARD_RECOVERY_TIMEOUT=${toString guard.recoveryTimeout}
      GUARD_POLL_INTERVAL=30
      GUARD_SYSTEMD_BIN=${escapeShellArg systemdBin}
    '' + builtins.readFile ../static/ceph-reboot-guard.sh;
  };

  # `reboot`, `poweroff` and `halt` in front of systemd's. The real ones are
  # called by store path, so there is no way for the wrapper to find itself.
  wrappers = pkgs.runCommand "ceph-reboot-guard-wrappers" { } ''
    mkdir -p $out/bin
    for action in reboot poweroff halt; do
      cat > $out/bin/$action <<EOF
    #!${pkgs.runtimeShell}
    exec ${ceph-reboot-guard}/bin/ceph-reboot-guard exec $action "\$@"
    EOF
      chmod +x $out/bin/$action
    done
  '';

in {
  config = mkMerge [
    (mkIf (configured && !hasCredentials) {
      warnings = [''
        Node '${nodeName}' is a Ceph-backed agent with storage.ceph.rebootGuard
        enabled but no `rebootGuard.tokenFile`, so it has no way to reach the
        Rook toolbox. Its reboots are NOT guarded and will trigger Ceph
        rebalancing.
      ''];
    })

    (mkIf active {
      environment.systemPackages = [ ceph-reboot-guard (hiPrio wrappers) ];

      systemd.services = {
        # Safety net for shutdowns that bypass the wrapper. A unit that is
        # "running" from boot and does its work in ExecStop; ordered after k3s
        # (and so stopped before it) so the API and the toolbox are still
        # reachable. The hook itself checks that a reboot or poweroff is
        # actually queued, so stopping the unit any other way is a no-op.
        ceph-reboot-guard-shutdown = {
          description = "Set Ceph noout/norebalance when this node shuts down";
          after = [ "k3s.service" "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/true";
            ExecStop = "${ceph-reboot-guard}/bin/ceph-reboot-guard shutdown-hook";
            TimeoutStopSec = "120s";
          };
        };

        # Not a oneshot: it can wait for hours, and a oneshot would hold up
        # boot and any deploy that starts it in the meantime.
        ceph-reboot-guard-recover = {
          description = "Unset Ceph noout/norebalance once this node has rejoined";
          after = [ "k3s.service" "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          restartIfChanged = false;
          serviceConfig = {
            Type = "simple";
            ExecStart = "${ceph-reboot-guard}/bin/ceph-reboot-guard recover";
            Restart = "on-failure";
            RestartSec = "60s";
            # 3 is "gave up after recoveryTimeout": leave the unit failed so it
            # shows in `systemctl --failed`, rather than retrying forever.
            RestartPreventExitStatus = 3;
          };
        };
      };
    })
  ];
}
