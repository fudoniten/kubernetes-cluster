# Pure-eval check of option plumbing across a two-cluster fleet.
#
# Evaluates one NixOS configuration per host and compares the facts the module
# derives — role, join address, flags, membership, gateway placement — against
# what the fleet definition should produce. No VM, no KVM, seconds to run.
{ lib, pkgs, module }:

with lib;

let
  system = pkgs.stdenv.hostPlatform.system;

  evalHost = hostName:
    (import "${pkgs.path}/nixos/lib/eval-config.nix" {
      inherit system;
      modules = [
        module
        ./fleet.nix
        {
          networking.hostName = hostName;
          system.stateVersion = "26.05";
          fileSystems."/" = {
            device = "/dev/sda1";
            fsType = "ext4";
          };
          boot.loader.grub.devices = [ "/dev/sda" ];
        }
      ];
    }).config;

  factsFor = hostName:
    let cfg = evalHost hostName;
    in {
      k3sEnabled = cfg.services.k3s.enable;
      role = cfg.services.k3s.role;
      serverAddr = cfg.services.k3s.serverAddr;
      clusterInit = cfg.services.k3s.clusterInit;
      tokenFile = cfg.services.k3s.tokenFile;
      extraFlags = cfg.services.k3s.extraFlags;
      inherit (cfg.services.kubernetes-cluster.membership)
        cluster isServer isPrimary isIngress isGpu;
      nginxEnabled = cfg.services.nginx.enable;
      cephModules = intersectLists cfg.boot.kernelModules [ "rbd" "ceph" ];
      containerdEnabled = cfg.virtualisation.containerd.enable;
      vhosts = sort lessThan (attrNames cfg.services.nginx.virtualHosts);
      # Normalised: the nat.forwardPorts submodule also carries `loopbackIPs`,
      # which this test has no opinion about.
      forwardPorts = map (rule: { inherit (rule) destination proto sourcePort; })
        cfg.networking.nat.forwardPorts;
      openTcpPorts = sort lessThan cfg.networking.firewall.allowedTCPPorts;
    };

  actual = genAttrs [ "a0" "a1" "b0" "b1" "gw" "outsider" ] factsFor;

  expected = {
    a0 = {
      k3sEnabled = true;
      role = "server";
      serverAddr = "";
      clusterInit = true;
      tokenFile = "/run/alpha/token";
      extraFlags = [
        "--tls-san=a0.alpha.example.com"
        "--node-label=tier=control"
        "--node-label=svccontroller.k3s.cattle.io/enablelb=true"
      ];
      cluster = "alpha";
      isServer = true;
      isPrimary = true;
      isIngress = true;
      isGpu = false;
      nginxEnabled = false;
      cephModules = [ "rbd" "ceph" ];
      containerdEnabled = false;
    };

    a1 = {
      k3sEnabled = true;
      role = "agent";
      # Joins through alpha's primary master, not its own address.
      serverAddr = "https://192.168.1.10:6443";
      clusterInit = false;
      tokenFile = "/run/alpha/token";
      cluster = "alpha";
      isServer = false;
      isPrimary = false;
      isIngress = false;
      isGpu = true;
      nginxEnabled = false;
      cephModules = [ "rbd" "ceph" ];
      containerdEnabled = true;
    };

    b0 = {
      k3sEnabled = true;
      role = "server";
      serverAddr = "";
      clusterInit = true;
      # beta's token, not alpha's: the two clusters must not bleed into
      # each other.
      tokenFile = "/run/beta/token";
      cluster = "beta";
      isServer = true;
      isPrimary = true;
      isIngress = false;
      isGpu = false;
      cephModules = [ ];
      containerdEnabled = false;
    };

    # Joins via beta's explicit joinEndpoint, not b0's address.
    b1 = {
      role = "server";
      serverAddr = "https://kube.beta.example.com:6443";
      clusterInit = false;
      tokenFile = "/run/beta/token";
    };

    # Gateway host: fronts both clusters but runs no kubelet. Building this
    # host's config from `cfg.clusters` is what made an earlier revision of
    # gateway.nix recurse, so the merge across two clusters is asserted here.
    gw = {
      k3sEnabled = false;
      cluster = null;
      nginxEnabled = true;
      vhosts = [
        "api.alpha.example.com"
        "api.internal.example.com"
        "beta-api.beta.example.com"
        "beta-api.internal.example.com"
        "dash.internal.example.com"
      ];
      # Forwarded to alpha's primary master, which is not the gateway itself.
      forwardPorts = [{
        destination = "192.168.1.10:9000";
        proto = "tcp";
        sourcePort = 9000;
      }];
      openTcpPorts = [ 9000 ];
    };

    # Named by no cluster and gatewaying none: gets nothing at all.
    outsider = {
      k3sEnabled = false;
      cluster = null;
      nginxEnabled = false;
      containerdEnabled = false;
      vhosts = [ ];
      forwardPorts = [ ];
    };
  };

  # Compare only the keys each expectation actually names, so a test can assert
  # one fact about a host without restating all of them.
  mismatches = concatLists (mapAttrsToList (host: want:
    mapAttrsToList (key: wanted:
      let got = actual.${host}.${key};
      in optional (got != wanted) {
        inherit host key wanted;
        inherit got;
      }) want) expected);

  # a1 must carry the GPU base labels; checked separately since extraFlags
  # ordering around the nvidia runtime flag is not worth pinning exactly.
  a1Flags = actual.a1.extraFlags;
  gpuLabelMissing = filter (label: !(elem "--node-label=${label}" a1Flags)) [
    "nvidia.com/gpu.present=true"
    "nixos-nvidia-cdi=enabled"
    "gpu=enabled"
  ];

  a1TaintMissing =
    optional (!(elem "--node-taint=dedicated=gpu:NoSchedule" a1Flags))
    "dedicated=gpu:NoSchedule";

  failures = mismatches ++ (map (l: "a1 missing GPU label ${l}") gpuLabelMissing)
    ++ (map (t: "a1 missing taint ${t}") a1TaintMissing);

in if failures == [ ] then
  pkgs.runCommand "kubernetes-cluster-eval-check" { } ''
    echo "all fleet expectations hold" > $out
  ''
else
  throw ''
    kubernetes-cluster eval check failed:
    ${generators.toPretty { } failures}
  ''
