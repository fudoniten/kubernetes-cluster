# NVIDIA GPU support: containerd with the nvidia runtime, CDI device injection,
# and a tagger that labels nodes by the devices they actually carry.
{ config, lib, pkgs, ... }:

with lib;

let
  inherit (import ../lib { inherit lib; }) mkContext;
  inherit (mkContext config) cluster nodeName isGpu;

  containerdSocket = "/run/containerd/containerd.sock";

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
    virtualisation.containerd = {
      enable = true;
      settings = {
        version = 2;
        root = "/var/lib/rancher/k3s/agent/containerd";
        state = "/run/k3s/containerd";
        grpc = { address = containerdSocket; };
        plugins = {
          "io.containerd.internal.v1.opt" = {
            path = "/var/lib/rancher/k3s/agent/containerd";
          };
          "io.containerd.grpc.v1.cri" = {
            stream_server_address = "127.0.0.1";
            stream_server_port = "10010";
            enable_cdi = true;
            cdi_spec_dirs = [ "/var/run/cdi" ];
            enable_selinux = false;
            enable_unprivileged_ports = true;
            enable_unprivileged_icmp = true;
            device_ownership_from_security_context = false;
            sandbox_image = "rancher/mirrored-pause:3.6";
            registry.config_path = "/etc/containerd/certs.d";
            cni = {
              bin_dir = "/var/lib/rancher/k3s/data/current/bin";
              conf_dir = "/var/lib/rancher/k3s/agent/etc/cni/net.d";
            };
            containerd = {
              snapshotter = "overlayfs";
              disable_snapshot_annotations = true;
              runtimes = {
                runc = {
                  runtime_type = "io.containerd.runc.v2";
                  options.SystemdCgroup = true;
                  runtimes.runhcs-wcow-process.runtime_type =
                    "io.containerd.runhcs.v1";
                };
                nvidia = {
                  runtime_type = "io.containerd.runc.v2";
                  privileged_without_host_devices = false;
                  options = {
                    Runtime = "nvidia";
                    BinaryName =
                      "${pkgs.nvidia-container-toolkit.tools}/bin/nvidia-container-runtime";
                    SystemdCgroup = true;
                    EnableCDI = true;
                    CDISpecDirs = [ "/var/run/cdi" ];
                  };
                };
              };
            };
          };
        };
      };
    };

    hardware = {
      graphics = {
        enable = true;
        enable32Bit = true;
      };
      nvidia-container-toolkit = {
        enable = true;
        discovery-mode = "nvml";
        device-name-strategy = "uuid";
      };
      nvidia = {
        powerManagement.enable = false;
        open = false;
      };
    };

    services = {
      xserver.videoDrivers = [ "nvidia" ];

      k3s.extraFlags = [ "--container-runtime-endpoint=${containerdSocket}" ];
    };

    systemd = {
      tmpfiles.settings."039-containerd" = {
        "${cluster.stateDirectory}/containerd/root".d = {
          mode = "0640";
          user = "root";
          group = "root";
        };
        "${cluster.stateDirectory}/containerd/state".d = {
          mode = "0640";
          user = "root";
          group = "root";
        };
      };

      services = {
        k3s = {
          requires = [ "containerd.service" ];
          after = [ "containerd.service" ];
          wantedBy = [ "multi-user.target" ];
        };

        containerd = {
          path = with pkgs; [
            nvidia-container-toolkit
            nvidia-container-toolkit.tools
            cudaPackages.cudatoolkit
            config.hardware.nvidia.package.out
            libnvidia-container
            runc
          ];
          environment = {
            CONTAINERD_ROOT = "${cluster.stateDirectory}/containerd/root/";
            CONTAINERD_STATE = "${cluster.stateDirectory}/containerd/state/";
            LD_LIBRARY_PATH =
              concatStringsSep ":" [ "${config.hardware.nvidia.package.out}/lib" ];
          };
          # Start after CDI specs are generated; nvidia-container-runtime 1.18+
          # defaults to CDI mode, so containerd needs the specs before accepting
          # GPU containers. Using `wants` (not `requires`) so containerd still
          # starts even if CDI generation fails.
          after = [ "nvidia-container-toolkit-cdi-generator.service" ];
          wants = [ "nvidia-container-toolkit-cdi-generator.service" ];
          wantedBy = [ "k3s.service" "multi-user.target" ];
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

    # nvidia-container-runtime needs an explicit config.toml with absolute Nix
    # store paths for runc and the hook, since containerd does not have the Nix
    # store in its PATH. Mode is "cdi" to use the specs generated by
    # nvidia-container-toolkit-cdi-generator.service rather than the legacy
    # NVML-hook path, which crashes on kernel 6.12.90+.
    environment.etc."nvidia-container-runtime/config.toml".text = ''
      disable-require = false

      [nvidia-container-cli]
        path = "${pkgs.libnvidia-container}/bin/nvidia-container-cli"
        ldconfig = "@${pkgs.glibc.bin}/bin/ldconfig"
        load-kmods = true
        no-cgroups = false

      [nvidia-container-runtime]
        debug = "/dev/null"
        log-level = "info"
        mode = "cdi"
        runtimes = ["${pkgs.runc}/bin/runc"]

      [nvidia-container-runtime.modes.cdi]
        default-kind = "nvidia.com/gpu"
        annotation-prefixes = ["cdi.k8s.io/"]
        spec-dirs = ["/var/run/cdi", "/etc/cdi"]

      [nvidia-container-runtime-hook]
        path = "${pkgs.nvidia-container-toolkit.tools}/bin/nvidia-container-runtime-hook"
        skip-error = false
    '';

    environment.systemPackages = with pkgs; [
      nvidia-container-toolkit
      nvidia-container-toolkit.tools
      cudaPackages.cudatoolkit
      config.hardware.nvidia.package.out
      libnvidia-container
      runc
    ];
  };
}
