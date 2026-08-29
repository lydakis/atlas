{
  nixpkgs,
  pkgs,
  installedSystem,
  installedTestStorageIds,
  installedTestUnlockKey,
}:
let
  inherit (nixpkgs.lib) mkForce;
  commonVm = {
    virtualisation = {
      cores = 2;
      diskImage = "./atlas-installed.qcow2";
      diskSize = 12 * 1024;
      memorySize = 3072;
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "atlas-installed-host";

  requiredFeatures.kvm = true;
  qemu.forceAccel = true;

  nodes = {
    installer =
      { config, pkgs, ... }:
      {
        imports = [
          commonVm
          "${nixpkgs}/nixos/tests/common/auto-format-root-device.nix"
        ];

        # Keep the installer itself on a disposable second disk so /dev/vda is
        # the empty target disk shared with the installed-host VM.
        virtualisation.emptyDiskImages = [ 1024 ];
        virtualisation.rootDevice = "/dev/vdb";
        virtualisation.fileSystems."/".autoFormat = true;

        boot.initrd.systemd.enable = true;
        hardware.enableAllFirmware = mkForce false;

        environment.systemPackages = with pkgs; [
          btrfs-progs
          cryptsetup
          dosfstools
          lvm2
          nixos-install-tools
          parted
        ];

        # The test is offline. Include the exact installed system in the live
        # installer's closure instead of consulting a binary cache.
        system.extraDependencies = [ installedSystem ];
        nix.settings = {
          substituters = mkForce [ ];
          hashed-mirrors = null;
          connect-timeout = 1;
        };
      };

    target = {
      imports = [ commonVm ];
      virtualisation = {
        useBootLoader = true;
        useDefaultFilesystems = false;
        useEFIBoot = true;
        efi.keepVariables = false;
        fileSystems."/" = {
          device = "/dev/disk/by-uuid/00000000-0000-4000-8000-000000000000";
          fsType = "ext4";
        };
      };
    };
  };

  testScript = ''
    import json
    import shlex

    installer.start()
    installer.wait_for_unit("multi-user.target")
    installer.succeed("udevadm settle")

    with subtest("Create the encrypted installed-host layout"):
        installer.succeed(
            "flock /dev/vda parted --script /dev/vda -- "
            "mklabel gpt "
            "mkpart ESP fat32 1MiB 513MiB "
            "set 1 esp on "
            "name 1 atlas-boot "
            "mkpart primary 513MiB 100% "
            "name 2 atlas-crypt",
            "udevadm settle",
            "printf %s ${installedTestUnlockKey} | "
            "cryptsetup luksFormat --batch-mode --type luks2 "
            "--uuid ${installedTestStorageIds.luksUuid} "
            "--pbkdf pbkdf2 --pbkdf-force-iterations 1000 /dev/vda2 -",
            "printf %s ${installedTestUnlockKey} | "
            "cryptsetup luksOpen --key-file - /dev/vda2 atlas-crypt",
            "pvcreate /dev/mapper/atlas-crypt",
            "vgcreate atlas /dev/mapper/atlas-crypt",
            "lvcreate --size 6G --name host atlas",
            "lvcreate --extents 100%FREE --name data atlas",
            "mkfs.vfat -F 32 -i ${builtins.replaceStrings [ "-" ] [ "" ] installedTestStorageIds.bootUuid} -n ATLAS-BOOT /dev/vda1",
            "mkfs.ext4 -F -U ${installedTestStorageIds.hostUuid} -L ATLAS-HOST /dev/atlas/host",
            "mkfs.btrfs -f -U ${installedTestStorageIds.dataUuid} -L ATLAS-DATA /dev/atlas/data",
            "udevadm settle",
            "mkdir -p /mnt",
            "mount /dev/disk/by-uuid/${installedTestStorageIds.hostUuid} /mnt",
            "mkdir -p /mnt/boot /mnt/var/lib/atlas",
            "mount /dev/disk/by-uuid/${installedTestStorageIds.bootUuid} /mnt/boot",
            "mount /dev/disk/by-uuid/${installedTestStorageIds.dataUuid} /mnt/var/lib/atlas",
        )

    with subtest("Install the declared Atlas system"):
        installer.succeed(
            "nixos-install --root /mnt --system ${installedSystem} "
            "--no-root-password < /dev/null >&2"
        )
        installer.succeed("test -e /mnt/boot/loader/loader.conf")
        installer.succeed("sync")
        installer.succeed("umount -R /mnt")

    installer.shutdown()

    # The installer and target are two views of the same persistent disk.
    target.state_dir = installer.state_dir

    def unlock_and_wait():
        target.start()
        target.wait_for_unit("multi-user.target")
        target.wait_for_unit("atlas-host.target")

    def entry(user, command, succeed=True):
        shell = target.succeed(f"getent passwd {user} | cut -d: -f7").strip()
        invocation = f"sudo -u {user} {shell} -c {shlex.quote(command)}"
        if succeed:
            return target.succeed(invocation)
        return target.fail(invocation)

    with subtest("Unlock and verify capacity isolation"):
        unlock_and_wait()
        target.succeed("cryptsetup status atlas-crypt")
        assert target.succeed("cryptsetup luksUUID /dev/vda2").strip() == "${installedTestStorageIds.luksUuid}"
        assert target.succeed("findmnt -n -o UUID /").strip() == "${installedTestStorageIds.hostUuid}"
        assert target.succeed("findmnt -n -o UUID /boot").strip() == "${installedTestStorageIds.bootUuid}"
        assert target.succeed("findmnt -n -o UUID /var/lib/atlas").strip() == "${installedTestStorageIds.dataUuid}"
        assert target.succeed("findmnt -n -o FSTYPE /var/lib/atlas").strip() == "btrfs"
        assert target.succeed("findmnt -n -o SOURCE /").strip() != target.succeed(
            "findmnt -n -o SOURCE /var/lib/atlas"
        ).strip()
        assert set(target.succeed("lvs --noheadings -o lv_name atlas").split()) == {
            "data",
            "host",
        }
        doctor = json.loads(target.succeed("atlas doctor --json"))["result"]
        assert doctor["storage"]["hostRecoveryReserve"] is True
        assert doctor["storage"]["atRestEncryption"] == {
            "mode": "luks2-operator-passphrase",
            "status": "experimental",
        }

    with subtest("Persist resettable and durable state across reboot"):
        entry("atlas-shared-dev", "echo installed-root > /etc/atlas-installed-root")
        entry("atlas-shared-dev", "echo owner-data > work/atlas-installed-owner-data")
        target.shutdown()
        unlock_and_wait()
        assert entry(
            "atlas-shared-dev", "cat /etc/atlas-installed-root"
        ).strip() == "installed-root"
        assert entry(
            "atlas-shared-dev", "cat work/atlas-installed-owner-data"
        ).strip() == "owner-data"

    with subtest("Reset preserves the declared durable work volume"):
        reset = json.loads(
            target.succeed("atlas environment reset shared-dev --json")
        )
        assert reset["ok"] is True
        entry("atlas-shared-dev", "test -e /etc/atlas-installed-root", succeed=False)
        assert entry(
            "atlas-shared-dev", "cat work/atlas-installed-owner-data"
        ).strip() == "owner-data"

    target.shutdown()
  '';
}
