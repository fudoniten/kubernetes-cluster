# NVIDIA GPU support: driver, CDI spec generation, and a tagger that labels
# nodes by the devices they actually carry.
#
# Device injection is CDI's job, and containerd does it natively. This module
# deliberately does NOT configure containerd: k3s manages its own, which reads
# CDI specs from /etc/cdi and /var/run/cdi. An earlier revision ran a separate
# containerd so the nvidia runtime could be wired in by hand, which meant
# owning containerd's config schema, its sandbox image and its GC behaviour —
# all three of which broke on a routine version bump, on GPU nodes only.
# Workloads request devices through the k8s device plugin; no RuntimeClass and
# no runtime wrapper are involved.
{ config, lib, pkgs, ... }:

with lib;

let
  inherit (import ../lib { inherit lib; }) mkContext;
  inherit (mkContext config) cluster node nodeName isGpu;

  deviceLabelMappings = pkgs.writeText "gpu-device-label-mappings.json"
    (generators.toJSON { } cluster.nvidia.deviceLabels);

  labeler = pkgs.callPackage ../pkgs/cdi-nvidia-device-labeler.nix { };

  # The null check keeps an unconfigured tagger from failing evaluation with a
  # coercion error before its assertion in modules/default.nix can report.
  taggerEnabled = cluster.nvidia.tagger.enable
    && cluster.nvidia.tagger.tokenFile != null;

  kubeMaster = let primary = cluster.nodes.${cluster.primaryMaster};
  in if primary.fqdn != null then primary.fqdn else primary.address;

in {
  config = mkIf isGpu {
    hardware = {
      graphics = {
        enable = true;
        enable32Bit = true;
      };

      # Generates the host CDI spec (vendor nvidia.com). Workloads no longer
      # inject from this one — see the driver-root note below — but the device
      # plugin's own pod does, which is how it gets an NVML to enumerate with.
      nvidia-container-toolkit = {
        enable = true;
        discovery-mode = "nvml";
        device-name-strategy = "uuid";
      };

      nvidia = {
        powerManagement.enable = false;
        open = false;
        # Pinned per node: the driver is system-wide, and a card older than
        # Turing needs the 580 branch that still supports it.
        package = mkIf (node.gpu.driverPackage != null) node.gpu.driverPackage;
      };
    };

    services.xserver.videoDrivers = [ "nvidia" ];

    # An FHS-shaped view of the driver, for the k8s device plugin alone.
    #
    # Under DEVICE_LIST_STRATEGY=cdi-cri the plugin does not inject from the
    # host spec generated above: it builds its own, vendored under
    # k8s.device-plugin.nvidia.com, from inside its container and hands those
    # device names to the kubelet over CRI. The nvidia-container-toolkit it
    # vendors is stock upstream, which locates driver libraries only under
    # /usr/lib64, /usr/lib/<triple>, /lib64 and /lib/<triple> beneath its
    # driver root, plus an ldcache we don't have. nixpkgs' dlopen discoverer —
    # the patch that lets nvidia-ctk work on NixOS at all — is not in that
    # image, and the plugin exposes no equivalent of --library-search-path.
    # Failing the lookup is fatal: it cannot generate a spec, so it exits.
    #
    # Bind mounts rather than symlinks, because the lookup resolves symlinks in
    # the *container's* mount namespace, where neither /run/opengl-driver nor
    # /nix/store exists. The driver's own directories are internally
    # consistent, so binding each one is both FHS-shaped and resolvable.
    #
    # Nothing outside the plugin's container consumes this: the plugin mounts
    # it at /driver-root and is told the host path via NVIDIA_DRIVER_ROOT.
    fileSystems = let
      nvidia = config.hardware.nvidia.package;
      bindRo = device: {
        inherit device;
        fsType = "none";
        options = [ "bind" "ro" ];
      };
    in {
      # Load-bearing: driver version inference, and every library mount in the
      # generated spec, hang off this one.
      "/run/nvidia-driver-root/usr/lib64" = bindRo "${getLib nvidia}/lib";
      # Optional — its discoverer is non-fatal — but it puts nvidia-smi and
      # friends into workload containers. GSP firmware is deliberately left
      # out: the host kernel module loads it, containers never read it.
      "/run/nvidia-driver-root/usr/bin" = bindRo "${getBin nvidia}/bin";
    };

    systemd = {
      services = {
        # Specs must exist before k3s starts accepting GPU containers. `wants`
        # rather than `requires` so a node still comes up — without working
        # GPUs — if spec generation fails, instead of losing the kubelet too.
        k3s = {
          after = [ "nvidia-container-toolkit-cdi-generator.service" ];
          wants = [ "nvidia-container-toolkit-cdi-generator.service" ];
        };

        nvidia-container-toolkit-cdi-generator = {
          # https://git.sr.ht/~goorzhel/nixos/tree/a806b38a14361e0eab2b1aca23f0b7d54e4c50f8/item/profiles/k3s/common/nvidia.nix#L15-18
          environment.LD_LIBRARY_PATH =
            "${config.hardware.nvidia.package.out}/lib";
        };

        gpu-node-tagger = mkIf taggerEnabled {
          description =
            "Tag GPU nodes with labels based on attached GPU devices, for scheduling by workload.";
          after = [ "network-online.target" ] ++ cluster.tokenReadyUnits;
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          path = with pkgs; [ babashka config.hardware.nvidia.package.bin ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = pkgs.writeShellScript "gpu-node-tagger.sh"
              (concatStringsSep " " ([
                "${labeler}/bin/cdi-nvidia-device-labeler"
                "--hostname=${nodeName}"
                "--device-map=${deviceLabelMappings}"
                "--token=${cluster.nvidia.tagger.tokenFile}"
                "--kube-master=${kubeMaster}"
                "--port=${toString cluster.apiPort}"
                "--cert=${cluster.nvidia.tagger.caCertFile}"
              ] ++ (optional cluster.verbose "--verbose")));
          };
        };
      };

      timers.gpu-node-tagger = mkIf taggerEnabled {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = cluster.nvidia.tagger.interval;
          OnUnitActiveSec = cluster.nvidia.tagger.interval;
        };
      };
    };

    # `nvidia-ctk` is worth having on the node to inspect and regenerate specs.
    # cudatoolkit and runc used to be here only to populate the hand-rolled
    # containerd's PATH; k3s brings its own runc, and cudatoolkit is several GB
    # of closure that nothing on the host consumes.
    environment.systemPackages = with pkgs; [
      nvidia-container-toolkit
      nvidia-container-toolkit.tools
      libnvidia-container
    ];
  };
}
