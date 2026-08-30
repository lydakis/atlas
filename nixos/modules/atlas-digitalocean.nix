{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.atlas.host.digitalOcean;
  inherit (lib) mkEnableOption mkIf mkOption types;
  volumeDevice = "/dev/disk/by-id/scsi-0DO_Volume_${cfg.dataVolumeName}";
in
{
  options.atlas.host.digitalOcean = {
    enable = mkEnableOption "the Atlas DigitalOcean dogfood storage adapter";

    dataVolumeName = mkOption {
      type = types.addCheck types.str (
        value: builtins.match "^[a-z0-9][a-z0-9-]{0,62}$" value != null
      );
      default = "atlas-data";
      description = ''
        DigitalOcean Block Storage volume name. Atlas resolves the provider's
        stable /dev/disk/by-id link and requires it to be explicitly formatted
        as Btrfs before the Atlas host starts.
      '';
    };
  };

  config = mkIf cfg.enable {
    atlas.host = {
      dataRootPersistence = "reboot-persistent";
      storage = {
        adapter = "btrfs-subvolume";
        atRestEncryption = "provider-managed-volume";
        hostRecoveryReserve = true;
      };
    };

    boot.initrd.availableKernelModules = [ "virtio_scsi" ];

    fileSystems."/var/lib/atlas" = {
      device = volumeDevice;
      fsType = "btrfs";
      options = [
        "discard=async"
        "nofail"
        "noatime"
      ];
    };

    systemd.services.atlas-digitalocean-volume-verify = {
      description = "Verify the Atlas DigitalOcean data volume";
      requiredBy = [ "var-lib-atlas.mount" ];
      before = [ "var-lib-atlas.mount" ];
      path = [
        pkgs.coreutils
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        device=${lib.escapeShellArg volumeDevice}

        for attempt in $(seq 1 30); do
          if [ -b "$device" ]; then
            break
          fi
          if [ "$attempt" -eq 30 ]; then
            echo "Atlas DigitalOcean data volume is unavailable: $device" >&2
            exit 1
          fi
          sleep 1
        done

        filesystem="$(blkid -o value -s TYPE "$device" 2>/dev/null || true)"
        if [ "$filesystem" != btrfs ]; then
          echo "Atlas requires an explicitly prepared Btrfs data volume at $device; found ''${filesystem:-no filesystem}" >&2
          exit 1
        fi
      '';
    };

    system.activationScripts = lib.mkIf (!config.atlas.host.bootstrapOpenSsh.enable) {
      atlasDigitalOceanBootstrapKeyCleanup = {
        deps = [ "users" ];
        text = ''
          # DigitalOcean's bootstrap unit writes this mutable file from
          # metadata. Disabling that unit does not remove the key it wrote.
          ${pkgs.coreutils}/bin/rm -f -- /root/.ssh/authorized_keys
        '';
      };
    };

    environment.etc."atlas/digitalocean-deployment.json".text = builtins.toJSON {
      provider = "digitalocean";
      dataVolume = {
        device = volumeDevice;
        name = cfg.dataVolumeName;
      };
      encryption = {
        authority = "provider";
        mode = "provider-managed-volume";
        ownerControlledUnlock = false;
      };
    };
  };
}
