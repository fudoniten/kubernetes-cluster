# Applies YAML in /etc/k3s to the cluster, once, from the primary master.
{ lib, pkgs, cluster, isMember, isPrimary, ... }:

with lib;

{
  config = mkIf isMember (mkMerge [
    {
      environment.etc = mapAttrs' (name: text:
        nameValuePair "k3s/${name}.yaml" {
          mode = "0750";
          inherit text;
        }) cluster.manifests;
    }

    (mkIf isPrimary {
      systemd.services.k3s-custom-configuration = {
        after = [ "k3s.service" ];
        wantedBy = [ "k3s.service" ];
        requires = [ "k3s.service" ];
        partOf = [ "k3s.service" ];
        path = with pkgs; [ kubectl ];
        description = "Run custom configurations in /etc/k3s";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "k3s-custom-configuration.sh" ''
            sleep 30  # Give time for k3s to start up before applying config
            for CONFIG in /etc/k3s/*.yaml; do
              echo "applying custom k3s config: $CONFIG"
              kubectl apply --kubeconfig=/etc/rancher/k3s/k3s.yaml -f $CONFIG
            done
          '';
        };
      };
    })
  ]);
}
