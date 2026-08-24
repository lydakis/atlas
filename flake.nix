{
  description = "Atlas NixOS host architecture spike";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;

      mkHost =
        system: extraModules:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.default
            ./nixos/configurations/spike-host.nix
          ]
          ++ extraModules;
        };

      mkVMHost =
        system:
        mkHost system [
          "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
          {
            virtualisation = {
              cores = 2;
              diskSize = 8192;
              graphics = false;
              memorySize = 2048;
            };
          }
        ];
    in
    {
      nixosModules.default = import ./nixos/modules/atlas-host.nix;

      nixosConfigurations = {
        atlas-spike-aarch64 = mkVMHost "aarch64-linux";
        atlas-spike-x86_64 = mkVMHost "x86_64-linux";
      };

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          vmHost = mkVMHost system;
          isoHost = mkHost system [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/iso-image.nix"
            {
              isoImage.squashfsCompression = "zstd -Xcompression-level 1";
            }
          ];
        in
        {
          default = vmHost.config.system.build.toplevel;
          vm = vmHost.config.system.build.vm;
          iso = isoHost.config.system.build.isoImage;
          host-contract = pkgs.writeText "atlas-host-contract.json" (
            builtins.toJSON vmHost.config.atlas.host.contract
          );
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          host-contract = import ./nixos/tests/host-contract.nix {
            inherit pkgs;
            atlasModule = self.nixosModules.default;
          };
        }
      );

      formatter = forAllSystems (system: (import nixpkgs { inherit system; }).nixfmt);
    };
}
