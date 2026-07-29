# Pure-eval check of option plumbing across a two-cluster fleet.
#
# Evaluates one NixOS configuration per host and compares the facts the module
# derives — role, join address, flags, membership, gateway placement — against
# what the fleet definition should produce. No VM, no KVM, seconds to run.
{ lib, pkgs, module }:

with lib;

let
  system = pkgs.stdenv.hostPlatform.system;

  baseHost = hostName: {
    networking = {
      hostName = hostName;
      # The gateway module sets nat.forwardPorts but deliberately configures no
      # NAT itself, matching the module this was extracted from — a gateway
      # host is expected to have NAT on for its own reasons. NixOS requires an
      # external interface alongside forwarded ports, so the host owes both.
      nat = {
        enable = true;
        externalInterface = "eth0";
      };
    };
    system.stateVersion = "26.05";
    fileSystems."/" = {
      device = "/dev/sda1";
      fsType = "ext4";
    };
    boot.loader.grub.devices = [ "/dev/sda" ];
    # The gateway requests ACME certificates for its external endpoints.
    security.acme = {
      acceptTerms = true;
      defaults.email = "test@example.com";
    };
  };

  evalWith = modules:
    (import "${pkgs.path}/nixos/lib/eval-config.nix" {
      inherit system;
      inherit modules;
    }).config;

  evalHost = hostName: evalWith [ module ./fleet.nix (baseHost hostName) ];

  # What NixOS itself reports at build time. The option checks below never
  # force `config.assertions`, so without this the module's own guardrails
  # would be entirely untested.
  failedAssertions = cfg:
    map (entry: entry.message) (filter (entry: !entry.assertion) cfg.assertions);

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
    #
    # `localhost` is nixpkgs' own default for services.nginx.virtualHosts, which
    # stands precisely because this module contributed no definition to override
    # it — the assertion is "none of gw's vhosts leaked here", and naming the
    # default is a truer way to say that than filtering it out.
    outsider = {
      k3sEnabled = false;
      cluster = null;
      nginxEnabled = false;
      containerdEnabled = false;
      vhosts = [ "localhost" ];
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

  # A well-formed fleet must trip nothing — neither this module's assertions
  # nor NixOS's.
  unexpectedAssertions = concatLists (map (host:
    map (msg: "${host}: unexpected assertion failure: ${msg}")
    (failedAssertions (evalHost host))) [ "a0" "a1" "b0" "gw" "outsider" ]);

  # The load-bearing safety property: services.k3s is a singleton, so a host
  # claimed by two clusters has to fail at eval rather than at 3am.
  doubleBooked = evalWith [
    module
    ./fleet.nix
    (baseHost "a0")
    {
      services.kubernetes-cluster.clusters.beta.nodes.a0 = {
        role = "agent";
        address = "192.168.2.99";
      };
    }
  ];

  doubleBookedCaught = any (msg: hasInfix "claimed by multiple" msg)
    (failedAssertions doubleBooked);

  missingGuard = optional (!doubleBookedCaught)
    "a host in two clusters did not trip the single-cluster assertion";

  failures = mismatches ++ (map (l: "a1 missing GPU label ${l}") gpuLabelMissing)
    ++ (map (t: "a1 missing taint ${t}") a1TaintMissing) ++ unexpectedAssertions
    ++ missingGuard;

in if failures == [ ] then
  pkgs.runCommand "kubernetes-cluster-eval-check" { } ''
    echo "all fleet expectations hold" > $out
  ''
else
  throw ''
    kubernetes-cluster eval check failed:
    ${generators.toPretty { } failures}
  ''
