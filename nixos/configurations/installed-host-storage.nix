{ config, lib, ... }:
let
  inherit (lib)
    mkOption
    toLower
    toUpper
    types
    ;
  cfg = config.atlas.host.installedStorage;
  uuidType = types.strMatching "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";
  fatUuidType = types.strMatching "[0-9a-fA-F]{4}-[0-9a-fA-F]{4}";
in
{
  options.atlas.host.installedStorage = {
    luksUuid = mkOption {
      type = uuidType;
      description = "Installer-generated UUID of the LUKS2 container.";
    };
    bootUuid = mkOption {
      type = fatUuidType;
      description = "Installer-generated UUID of the EFI system filesystem.";
    };
    hostUuid = mkOption {
      type = uuidType;
      description = "Installer-generated UUID of the fixed host filesystem.";
    };
    dataUuid = mkOption {
      type = uuidType;
      description = "Installer-generated UUID of the elastic Atlas filesystem.";
    };
  };

  config = {
    # The physical-alpha storage layout is one operator-unlocked LUKS2 container
    # with separate logical volumes for the host and Atlas data. The fixed host
    # volume remains operable when the elastic Atlas Btrfs volume is full. Every
    # device reference is installation-specific; labels remain diagnostic only.
    boot = {
      initrd = {
        availableKernelModules = [
          "ahci"
          "nvme"
          "sd_mod"
          "usb_storage"
          "virtio_blk"
          "virtio_pci"
          "virtio_scsi"
          "xhci_pci"
        ];
        luks.devices.atlas-crypt = {
          device = "/dev/disk/by-uuid/${toLower cfg.luksUuid}";
          allowDiscards = false;
        };
        services.lvm.enable = true;
        systemd.enable = true;
      };

      loader = {
        efi.canTouchEfiVariables = false;
        systemd-boot.enable = true;
      };
    };

    fileSystems = {
      "/" = {
        device = "/dev/disk/by-uuid/${toLower cfg.hostUuid}";
        fsType = "ext4";
      };
      "/boot" = {
        device = "/dev/disk/by-uuid/${toUpper cfg.bootUuid}";
        fsType = "vfat";
        options = [
          "fmask=0077"
          "dmask=0077"
        ];
      };
      "/var/lib/atlas" = {
        device = "/dev/disk/by-uuid/${toLower cfg.dataUuid}";
        fsType = "btrfs";
        neededForBoot = true;
        options = [
          "compress=zstd"
          "noatime"
        ];
      };
    };

    atlas.host = {
      dataRootPersistence = "reboot-persistent";
      storage = {
        adapter = "btrfs-subvolume";
        atRestEncryption = "luks2-operator-passphrase";
        hostRecoveryReserve = true;
      };
    };
  };
}
