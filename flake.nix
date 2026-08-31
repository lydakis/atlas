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
      installedTestUnlockKey = "atlas-test-only-passphrase";
      installedTestStorageIds = {
        luksUuid = "11111111-2222-4333-8444-555555555555";
        bootUuid = "A71A-5001";
        hostUuid = "66666666-7777-4888-8999-aaaaaaaaaaaa";
        dataUuid = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff";
      };

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
          ./nixos/configurations/btrfs-vm-storage.nix
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

      mkInstalledTestHost =
        system:
        mkHost system [
          ./nixos/configurations/installed-host-storage.nix
          "${nixpkgs}/nixos/modules/testing/test-instrumentation.nix"
          (
            { pkgs, ... }:
            let
              keyFile = pkgs.writeText "atlas-installed-test-luks-key" installedTestUnlockKey;
            in
            {
              atlas.host.installedStorage = installedTestStorageIds;

              # Automated VM boot uses a test-only initrd key. The reusable
              # installed-storage module remains operator-passphrase only.
              boot.initrd = {
                luks.devices.atlas-crypt.keyFile = "/atlas-installed-test-luks-key";
                secrets."/atlas-installed-test-luks-key" = keyFile;
              };
            }
          )
        ];

      mkDigitalOceanHost =
        bootstrap:
        mkHost "x86_64-linux" [
          "${nixpkgs}/nixos/modules/virtualisation/digital-ocean-config.nix"
          self.nixosModules.digitalocean
          {
            atlas.host = {
              bootstrapOpenSsh.enable = bootstrap;
              digitalOcean.enable = true;
            };
            services.openssh.enable = nixpkgs.lib.mkForce bootstrap;
            virtualisation.digitalOcean.setSshKeys = bootstrap;
          }
        ];

      digitalOceanBootstrapHost = mkDigitalOceanHost true;
      digitalOceanHost = mkDigitalOceanHost false;
      digitalOceanImageHost = mkHost "x86_64-linux" [
        "${nixpkgs}/nixos/modules/virtualisation/digital-ocean-image.nix"
        self.nixosModules.digitalocean
        {
          atlas.host = {
            bootstrapOpenSsh.enable = true;
            digitalOcean.enable = true;
          };
          environment.etc."atlas/image-source".source = self;
          image.baseName = "atlas-digitalocean-x86_64";
          virtualisation = {
            digitalOcean.setSshKeys = true;
            diskSize = 8192;
          };
        }
      ];
    in
    {
      nixosModules.default = import ./nixos/modules/atlas-host.nix;
      nixosModules.digitalocean = import ./nixos/modules/atlas-digitalocean.nix;
      nixosModules.installed-storage = import ./nixos/configurations/installed-host-storage.nix;

      nixosConfigurations = {
        atlas-spike-aarch64 = mkVMHost "aarch64-linux";
        atlas-spike-x86_64 = mkVMHost "x86_64-linux";
        atlas-digitalocean-bootstrap-x86_64 = digitalOceanBootstrapHost;
        atlas-digitalocean-x86_64 = digitalOceanHost;
      };

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          vmHost = mkVMHost system;
          isoHost = mkHost system [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/iso-image.nix"
            {
              atlas.host.dataRootPersistence = "volatile-live-image";
              atlas.host.storage.adapter = nixpkgs.lib.mkForce "host-directory";
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
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          digitalocean-image = digitalOceanImageHost.config.system.build.digitalOceanImage;
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
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.git
                  pkgs.python3
                ];
              }
              ''
                mkdir -p work/scripts work/src work/tests
                cp -r ${./src/atlas} work/src/atlas
                cp ${./tests/test_atlas_control.py} work/tests/test_atlas_control.py
                cp ${./tests/test_remote_check.py} work/tests/test_remote_check.py
                install -m 0755 ${./scripts/remote-check} work/scripts/remote-check
                cd work
                python3 -m unittest discover -s tests -v
                touch "$out"
              '';
          module-evaluation = import ./nixos/tests/module-evaluation.nix {
            inherit pkgs;
            inherit (nixpkgs) lib;
            atlasModule = self.nixosModules.default;
            digitalOceanModule = self.nixosModules.digitalocean;
            installedStorageModule = self.nixosModules.installed-storage;
          };
          host-contract = import ./nixos/tests/host-contract.nix {
            inherit pkgs;
            atlasModule = self.nixosModules.default;
          };
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          # The physical alpha targets generic x86 hardware. Keep this slow
          # installed-disk acceptance proof off unrelated architectures.
          installed-host = import ./nixos/tests/installed-host.nix {
            inherit
              nixpkgs
              pkgs
              installedTestStorageIds
              installedTestUnlockKey
              ;
            installedSystem = (mkInstalledTestHost system).config.system.build.toplevel;
          };
          incus-substrate = import ./nixos/tests/incus-substrate.nix { inherit pkgs; };
        }
      );

      formatter = forAllSystems (system: (import nixpkgs { inherit system; }).nixfmt);
    };
}
