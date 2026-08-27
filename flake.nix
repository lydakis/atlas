{
  description = "Atlas physical-first NixOS host architecture spike";

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

            # The development VM has no public listener. Give its local serial
            # console a bootstrap path so an operator can enroll Tailscale and
            # then exercise the same fixed environment logins as physical
            # hardware. Cloud and physical artifacts configure their own entry.
            networking.hostName = nixpkgs.lib.mkForce "atlas-spike-local";
            services.getty.autologinUser = "atlas-operator";
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
              services.openssh.enable = nixpkgs.lib.mkForce false;
              services.getty.autologinUser = "atlas-operator";
              users.users.root.hashedPassword = nixpkgs.lib.mkForce "!";
              environment.etc."motd".text = ''
                Atlas physical-host spike

                This is a non-persistent live image. To enroll the host into
                Tailscale and enable private SSH, run:

                  sudo atlas-enroll
              '';
            }
          ];
        in
        {
          default = vmHost.config.system.build.toplevel;
          vm = vmHost.config.system.build.vm;
          iso = isoHost.config.system.build.isoImage;
          physical-iso = isoHost.config.system.build.isoImage;
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
          control-unit =
            pkgs.runCommand "atlas-control-unit"
              {
                nativeBuildInputs = [ pkgs.python3 ];
              }
              ''
                mkdir -p work/src work/tests
                cp ${./src/atlas_control.py} work/src/atlas_control.py
                cp ${./tests/test_atlas_control.py} work/tests/test_atlas_control.py
                cd work
                python3 -m unittest discover -s tests -v
                touch "$out"
              '';
          module-evaluation = import ./nixos/tests/module-evaluation.nix {
            inherit pkgs;
            inherit (nixpkgs) lib;
            atlasModule = self.nixosModules.default;
          };
          host-contract = import ./nixos/tests/host-contract.nix {
            inherit pkgs;
            atlasModule = self.nixosModules.default;
          };
        }
      );

      formatter = forAllSystems (system: (import nixpkgs { inherit system; }).nixfmt);
    };
}
