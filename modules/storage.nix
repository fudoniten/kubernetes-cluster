# Ceph support on cluster nodes: RBD kernel modules and the mount helper.
#
# k3s resolves mount helpers via the conventional /sbin and /usr/sbin paths,
# neither of which exists on NixOS, so mount.ceph is symlinked into place.
{ config, lib, pkgs, ... }:

with lib;

let
  inherit (import ../lib { inherit lib; }) mkContext;
  inherit (mkContext config) cluster isMember;

in {
  config = mkIf (isMember && cluster.storage.ceph.enable) {
    boot.kernelModules = [ "rbd" "libceph" "ceph" ];

    environment.systemPackages = with pkgs; [ ceph ];

    systemd.tmpfiles.settings."040-kubernetes" = {
      "/sbin/mount.ceph"."L+".argument = "${pkgs.ceph}/bin/mount.ceph";
      "/usr/sbin/mount.ceph"."L+".argument = "${pkgs.ceph}/bin/mount.ceph";
    };
  };
}
