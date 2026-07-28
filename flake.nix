{
  description = "Generic multi-cluster k3s NixOS module";

  inputs.nixpkgs.url = "nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

    in {
      nixosModules = rec {
        kubernetes-cluster = ./modules;
        default = kubernetes-cluster;
      };

      lib = import ./lib { inherit lib; };

      packages = forAllSystems (pkgs: rec {
        cdi-nvidia-device-labeler =
          pkgs.callPackage ./pkgs/cdi-nvidia-device-labeler.nix { };
        default = cdi-nvidia-device-labeler;
      });

      checks = forAllSystems (pkgs:
        {
          inherit (self.packages.${pkgs.stdenv.hostPlatform.system})
            cdi-nvidia-device-labeler;

          # Fast, pure-eval check of option plumbing: builds NixOS toplevels for
          # a small two-cluster fleet and asserts the resulting k3s roles,
          # flags and membership. Catches the mis-wiring that a refactor of this
          # shape is actually prone to, without needing KVM.
          eval = import ./tests/eval.nix {
            inherit lib pkgs;
            module = self.nixosModules.default;
          };
        } // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
          # Real two-cluster VM test. Needs KVM, several GB of RAM and a few
          # minutes; excluded on aarch64 where k3s images are less reliable.
          two-clusters = pkgs.testers.runNixOSTest (import ./tests/two-clusters.nix {
            module = self.nixosModules.default;
          });
        });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-classic);
    };
}
