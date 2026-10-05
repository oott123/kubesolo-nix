{
  description = "KubeSolo package and NixOS module";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      overlays.default = final: _prev: {
        kubesolo = final.callPackage ./pkgs/kubesolo { };
      };

      packages = forAllSystems (pkgs: rec {
        kubesolo = pkgs.callPackage ./pkgs/kubesolo { };
        default = kubesolo;
      });

      nixosModules = {
        kubesolo =
          { lib, pkgs, ... }:
          {
            imports = [ ./modules/kubesolo.nix ];
            services.kubesolo.package = lib.mkDefault (pkgs.callPackage ./pkgs/kubesolo { });
          };
        default = self.nixosModules.kubesolo;
      };

      checks = forAllSystems (pkgs: {
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) kubesolo;
        nixos = pkgs.testers.runNixOSTest {
          imports = [ ./tests/kubesolo.nix ];
          defaults.imports = [ self.nixosModules.kubesolo ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
