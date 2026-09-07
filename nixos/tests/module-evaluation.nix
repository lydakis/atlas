{
  atlasModule,
  digitalOceanModule,
  installedStorageModule,
  lib,
  pkgs,
}:
let
  mkHost =
    extraModule:
    lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        atlasModule
        ../configurations/spike-host.nix
        extraModule
      ];
    };

  defaultHost = mkHost { };

  authKeyType = defaultHost.options.atlas.host.tailscale.authKeyFile.type;
  dataRootType = defaultHost.options.atlas.host.dataRoot.type;

  runtimeSecretPath = "/run/secrets/atlas-tailscale-auth-key";
  runtimeSecretHost = mkHost {
    atlas.host.tailscale.authKeyFile = runtimeSecretPath;
  };
  runtimeSecretPreStart = runtimeSecretHost.config.systemd.services.tailscaled-autoconnect.preStart;
  runtimeSecretScript = runtimeSecretHost.config.systemd.services.tailscaled-autoconnect.script;

  disabledTailscaleHost = mkHost {
    atlas.host.tailscale.enable = lib.mkForce false;
  };

  volatileStateHost = mkHost {
    atlas.host.dataRootPersistence = "volatile-live-image";
    atlas.host.storage.adapter = lib.mkForce "host-directory";
  };

  encryptedStorageHost = mkHost {
    atlas.host.storage = {
      atRestEncryption = "luks2-operator-passphrase";
      hostRecoveryReserve = true;
    };
  };

  mkDigitalOceanHost =
    bootstrap:
    lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        atlasModule
        digitalOceanModule
        ../configurations/spike-host.nix
        (
          { modulesPath, ... }:
          {
            imports = [ "${modulesPath}/virtualisation/digital-ocean-config.nix" ];

            atlas.host = {
              bootstrapOpenSsh.enable = bootstrap;
              digitalOcean.enable = true;
            };
            services.openssh.enable = lib.mkForce bootstrap;
            virtualisation.digitalOcean.setSshKeys = bootstrap;
          }
        )
      ];
    };
  digitalOceanBootstrapHost = mkDigitalOceanHost true;
  digitalOceanSteadyHost = mkDigitalOceanHost false;
  digitalOceanContract = digitalOceanBootstrapHost.config.atlas.host.contract;
  digitalOceanPrepare =
    digitalOceanBootstrapHost.config.systemd.services.atlas-digitalocean-volume-verify.script;
  digitalOceanSteadyActivation =
    digitalOceanSteadyHost.config.system.activationScripts.atlasDigitalOceanBootstrapKeyCleanup.text;

  alternateOwnerHomeHost = mkHost {
    atlas.host.owner.homeVolumeId = lib.mkForce "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  };

  sharedWithoutOwnerHomeHost = mkHost {
    atlas.host.environments.shared-dev.ownerHome = lib.mkForce false;
  };

  installedStorageIds = {
    luksUuid = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE";
    bootUuid = "a71a-5001";
    hostUuid = "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF";
    dataUuid = "CCCCCCCC-DDDD-4EEE-8FFF-AAAAAAAAAAAA";
  };
  installedStorageHost = lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      atlasModule
      installedStorageModule
      ../configurations/spike-host.nix
      { atlas.host.installedStorage = installedStorageIds; }
    ];
  };

  packageCompositionHost = mkHost {
    atlas.host = {
      environmentLayers = {
        package-first.packages = {
          instanceWinner = pkgs.hello;
          layerWinner = pkgs.hello;
        };
        package-second.packages = {
          instanceWinner = pkgs.gnugrep;
          layerWinner = pkgs.gnugrep;
        };
      };
      environments.shared-dev = {
        layers = lib.mkForce [
          "package-first"
          "package-second"
        ];
        packages.instanceWinner = pkgs.findutils;
      };
    };
  };

  failedMessages =
    module:
    map (assertion: assertion.message) (
      builtins.filter (assertion: !assertion.assertion) (mkHost module).config.assertions
    );
  hasFailedMessage =
    needle: module: builtins.any (message: lib.hasInfix needle message) (failedMessages module);

  expectedStateDirectories = {
    audit = {
      group = "atlas-control";
      mode = "0750";
      owner = "atlas-control";
    };
    browser-profiles = {
      group = "root";
      mode = "0711";
      owner = "root";
    };
    caches = {
      group = "root";
      mode = "0711";
      owner = "root";
    };
    control = {
      group = "atlas-control";
      mode = "0700";
      owner = "atlas-control";
    };
    credentials = {
      group = "atlas-control";
      mode = "0700";
      owner = "atlas-control";
    };
    environments = {
      group = "root";
      mode = "0711";
      owner = "root";
    };
    grants = {
      group = "atlas-control";
      mode = "0700";
      owner = "atlas-control";
    };
    recordings = {
      group = "root";
      mode = "0711";
      owner = "root";
    };
    routes = {
      group = "atlas-control";
      mode = "0750";
      owner = "atlas-control";
    };
    volumes = {
      group = "root";
      mode = "0711";
      owner = "root";
    };
  };

  defaultContract = defaultHost.config.atlas.host.contract;
  disabledContract = disabledTailscaleHost.config.atlas.host.contract;
  volatileContract = volatileStateHost.config.atlas.host.contract;
in
assert !(authKeyType.check ../../README.md);
assert authKeyType.check runtimeSecretPath;
assert !(authKeyType.check "/nix/store/example-auth-key");
assert !(authKeyType.check "/nix/./store/example-auth-key");
assert lib.hasInfix ''readlink -f -- "$auth_key_path"'' runtimeSecretPreStart;
assert lib.hasInfix "/nix/store|/nix/store/*" runtimeSecretPreStart;
assert !(dataRootType.check ../../README.md);
assert dataRootType.check "/var/lib/atlas";
assert !(dataRootType.check "/srv/atlas");
assert !(dataRootType.check "/");
assert !(dataRootType.check "/var");
assert !(dataRootType.check "/var/lib");
assert !(dataRootType.check "/etc/ssh");
assert !(dataRootType.check "//var/lib/atlas");
assert !(dataRootType.check "/var/lib/atlas/..");
assert !(dataRootType.check "/nix/store/atlas-state");
assert lib.hasInfix "cat ${runtimeSecretPath}" runtimeSecretScript;
assert !(lib.hasInfix "/nix/store" runtimeSecretScript);
assert defaultContract.version == 7;
assert
  defaultContract.intent.primitives == [
    "host"
    "environment"
    "volume"
    "grant"
    "surface"
    "route"
  ];
assert
  defaultContract.implementation.primitives == [
    "host"
    "environment"
    "volume"
  ];
assert defaultContract.state.root == "/var/lib/atlas";
assert defaultContract.state.persistence == "reboot-persistent";
assert defaultContract.state.storageAdapter == "btrfs-subvolume";
assert defaultContract.state.rootMode == "0711";
assert defaultContract.state.directories == expectedStateDirectories;
assert defaultContract.configuration.connectivity.openSshConfigured == false;
assert defaultContract.configuration.connectivity.openSshMode == "disabled";
assert defaultContract.configuration.connectivity.tailscale.adapterEnabled == true;
assert defaultContract.configuration.connectivity.tailscale.sshRequested == true;
assert defaultContract.configuration.connectivity.tailscale.enrollmentMode == "interactive";
assert digitalOceanContract.configuration.connectivity.openSshConfigured == true;
assert
  digitalOceanContract.configuration.connectivity.openSshMode == "bootstrap-root-public-key-only";
assert digitalOceanBootstrapHost.config.services.openssh.settings.AllowUsers == [ "root" ];
assert
  digitalOceanBootstrapHost.config.services.openssh.settings.AuthenticationMethods == "publickey";
assert digitalOceanBootstrapHost.config.services.openssh.settings.PasswordAuthentication == false;
assert
  digitalOceanBootstrapHost.config.services.openssh.settings.KbdInteractiveAuthentication == false;
assert
  digitalOceanBootstrapHost.config.services.openssh.settings.PermitRootLogin == "prohibit-password";
assert digitalOceanBootstrapHost.config.networking.firewall.allowedTCPPorts == [ 22 ];
assert hasFailedMessage "exact root public-key-only policy" {
  atlas.host.bootstrapOpenSsh.enable = true;
  services.openssh.settings.PasswordAuthentication = lib.mkForce true;
};
assert hasFailedMessage "exact root public-key-only policy" {
  atlas.host.bootstrapOpenSsh.enable = true;
  services.openssh.settings.AllowUsers = lib.mkForce [
    "owner"
    "root"
  ];
};
assert hasFailedMessage "exact root public-key-only policy" {
  atlas.host.bootstrapOpenSsh.enable = true;
  services.openssh.extraConfig = ''
    Match User root
      AuthenticationMethods password
      PasswordAuthentication yes
  '';
};
assert hasFailedMessage "must match the effective OpenSSH service state" {
  atlas.host.bootstrapOpenSsh.enable = true;
  services.openssh.enable = lib.mkForce false;
};
assert digitalOceanSteadyHost.config.virtualisation.digitalOcean.setSshKeys == false;
assert lib.hasInfix "rm -f -- /root/.ssh/authorized_keys" digitalOceanSteadyActivation;
assert digitalOceanBootstrapHost.config.atlas.host.storage.hostRecoveryReserve == true;
assert
  digitalOceanBootstrapHost.config.atlas.host.storage.atRestEncryption == "provider-managed-volume";
assert
  digitalOceanBootstrapHost.config.fileSystems."/var/lib/atlas".device
  == "/dev/disk/by-id/scsi-0DO_Volume_atlas-data";
assert lib.hasInfix ''filesystem="$(blkid -o value -s TYPE "$device"'' digitalOceanPrepare;
assert lib.hasInfix "requires an explicitly prepared Btrfs data volume" digitalOceanPrepare;
assert !(lib.hasInfix "mkfs" digitalOceanPrepare);
assert defaultContract.configuration.environmentEntry.version == 7;
assert defaultContract.configuration.environmentEntry.adapter == "nixos-incus-btrfs-v0";
assert defaultContract.configuration.environmentEntry.composition.declarative == true;
assert defaultContract.configuration.environmentEntry.composition.runtimeCreation == false;
assert defaultContract.configuration.environmentEntry.composition.disposableRoots == false;
assert defaultContract.configuration.environmentEntry.composition.resettableRoots == true;
assert defaultContract.configuration.environmentEntry.composition.rebootPersistentRoots == true;
assert defaultContract.configuration.environmentEntry.composition.durableVolumes == true;
assert defaultContract.configuration.environmentEntry.composition.persistentInstances == true;
assert defaultContract.configuration.environmentEntry.composition.concurrentEntry == true;
assert defaultContract.configuration.environmentEntry.composition.durableOwnerHome == true;
assert defaultContract.configuration.environmentEntry.composition.resettableHomePaths == true;
assert
  defaultContract.configuration.environmentEntry.owner == {
    home = "/home/owner";
    homeStorage = {
      durability = "host-durable";
      hostPath = "/var/lib/atlas/volumes/dddddddd-dddd-4ddd-8ddd-dddddddddddd/data";
      id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    };
    name = "owner";
    uid = 1000;
  };
assert
  defaultContract.configuration.environmentEntry.volumes.projects == {
    durability = "host-durable";
    hostPath = "/var/lib/atlas/volumes/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/data";
    id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    name = "projects";
  };
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.variables == {
    DEMO_API_ORIGIN = "https://example.invalid";
    DEMO_BASE = "base";
    DEMO_GENERATION = "baseline";
    DEMO_NODE = "enabled";
    DEMO_OVERRIDE = "instance";
  };
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.packages == {
    git = "git";
    python = "python3";
  };
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.git.config.user.name
  == "George Lydakis";
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.git.config.user.email
  == "atlas@labblue.ai";
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.git.config.init.defaultBranch
  == "main";
assert
  defaultContract.configuration.environmentEntry.environments.personal-dev.git.config.user.email
  == "george@lydakis.me";
assert defaultContract.configuration.environmentEntry.environments.restricted.packages == { };
assert defaultContract.configuration.environmentEntry.environments.shared-dev.home == "/home/owner";
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.homeComposition == {
    durable = true;
    durableHostPath = "/var/lib/atlas/volumes/dddddddd-dddd-4ddd-8ddd-dddddddddddd/data";
    resettablePaths = [
      ".cache"
      ".config"
      ".local/bin"
      ".local/state"
    ];
  };
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.user == {
    elevation = "passwordless-environment-sudo";
    name = "owner";
    uid = 1000;
  };
assert
  defaultContract.configuration.environmentEntry.environments.restricted.homeComposition == {
    durable = false;
    resettablePaths = [ ];
  };
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.volumes == [
    {
      access = "read-write";
      hostPath = "/var/lib/atlas/volumes/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/data";
      id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      name = "projects";
      target = "/home/owner/Projects";
    }
  ];
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.lifecycle
  == "resettable";
assert
  builtins.match "[0-9a-f]{64}" defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.layoutId
  != null;
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.layoutId
  != defaultContract.configuration.environmentEntry.environments.restricted.runtime.layoutId;
assert
  alternateOwnerHomeHost.config.atlas.host.environmentContract.environments.shared-dev.runtime.layoutId
  != defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.layoutId;
assert
  alternateOwnerHomeHost.config.atlas.host.environmentContract.environments.restricted.runtime.layoutId
  == defaultContract.configuration.environmentEntry.environments.restricted.runtime.layoutId;
assert
  sharedWithoutOwnerHomeHost.config.atlas.host.environmentContract.environments.shared-dev.runtime.layoutId
  != defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.layoutId;
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.persistence
  == "until-explicit-reset";
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.backend
  == "incus-container";
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.storage.adapter
  == "incus-btrfs-subvolume-pool";
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.storage.copyOnWrite
  == true;
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.storage.snapshots;
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.instance.name
  == "atlas-shared-dev";
assert lib.hasPrefix "/nix/store/"
  defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.instance.resetCommand;
assert lib.hasPrefix "/nix/store/"
  defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.instance.verifyCommand;
assert
  builtins.stringLength defaultContract.configuration.environmentEntry.baseImage.contentId == 64;
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.process.serviceUnit
  == "incus.service";
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.process.cgroupPrefix
  == "/lxc.payload.atlas-shared-dev";
assert
  packageCompositionHost.config.atlas.host.environmentContract.environments.shared-dev.packages == {
    instanceWinner = lib.getName pkgs.findutils;
    layerWinner = lib.getName pkgs.gnugrep;
  };
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.entry.loginUser
  == "atlas-shared-dev";
assert defaultHost.config.users.users.atlas-shared-dev.uid == 23001;
assert defaultHost.config.users.users.atlas-restricted.uid == 23002;
assert defaultHost.config.users.users.atlas-personal-dev.uid == 23003;
assert defaultHost.config.systemd.sockets.atlas-control.socketConfig.SocketMode == "0666";
assert
  defaultHost.config.systemd.sockets.atlas-control.socketConfig.ListenStream
  == "/run/atlas/public/control.sock";
assert defaultHost.config.systemd.sockets.atlas-manage.socketConfig.SocketMode == "0600";
assert
  defaultHost.config.systemd.services."atlas-environment-shared\\x2ddev".serviceConfig.Type
  == "oneshot";
assert defaultHost.config.systemd.services.atlas-guest-contract.restartTriggers != [ ];
assert builtins.elem "atlas-guest-contract.service"
  defaultHost.config.systemd.services."atlas-environment-shared\\x2ddev".requires;
assert builtins.hasAttr "atlas-incus-inventory" defaultHost.config.systemd.services;
assert builtins.elem "atlas-incus-inventory.service"
  defaultHost.config.systemd.services."atlas-environment-shared\\x2ddev".requires;
assert defaultHost.config.systemd.services.atlas-storage-prepare.serviceConfig.Type == "oneshot";
assert lib.hasInfix "systemd-tmpfiles --create --prefix=/var/lib/atlas"
  defaultHost.config.systemd.services.atlas-storage-prepare.script;
assert lib.hasInfix
  "CapabilityBoundingSet=CAP_DAC_READ_SEARCH\nCapabilityBoundingSet=CAP_SYS_ADMIN\n"
  defaultHost.config.systemd.units."atlas-manage.service".text;
assert lib.hasInfix "CapabilityBoundingSet=CAP_DAC_READ_SEARCH"
  volatileStateHost.config.systemd.units."atlas-manage.service".text;
assert lib.hasInfix "RequiresMountsFor=/var/lib/atlas"
  digitalOceanBootstrapHost.config.systemd.units."incus.service".text;
assert defaultHost.config.systemd.services.atlas-manage.serviceConfig.RestrictSUIDSGID;
assert defaultHost.config.virtualisation.incus.enable;
assert defaultHost.config.virtualisation.incus.package == pkgs.incus-lts;
assert builtins.elem "atlasbr0" defaultHost.config.networking.firewall.trustedInterfaces;
assert lib.hasInfix ''iifname "atlasbr0" tcp dport 53 accept''
  defaultHost.config.networking.nftables.tables.atlas-host-input.content;
assert lib.hasInfix ''iifname "atlasbr0" udp dport { 53, 67 } accept''
  defaultHost.config.networking.nftables.tables.atlas-host-input.content;
assert lib.hasInfix "fib daddr type { local, broadcast, multicast } drop"
  defaultHost.config.networking.nftables.tables.atlas-host-input.content;
assert
  !(builtins.any (
    mount: lib.hasPrefix "/run/atlas/environments" mount.where
  ) defaultHost.config.systemd.mounts);
assert
  !(builtins.hasAttr "atlas-environment-storage-shared\\x2ddev" defaultHost.config.systemd.services);
assert defaultHost.config.nix.settings.allowed-users == [ "root" ];
assert defaultHost.config.nix.settings.trusted-users == [ "root" ];
assert hasFailedMessage "unknown layers" {
  atlas.host.environments.shared-dev.layers = lib.mkForce [ "missing" ];
};
assert hasFailedMessage "cannot repeat" {
  atlas.host.environments.shared-dev.layers = lib.mkForce [
    "base"
    "base"
  ];
};
assert hasFailedMessage "IDs must be unique" {
  atlas.host.environments.restricted.id = lib.mkForce "11111111-1111-4111-8111-111111111111";
};
assert hasFailedMessage "UIDs must be unique" {
  atlas.host.environments.restricted.uid = lib.mkForce 23001;
};
assert hasFailedMessage "unknown volumes" {
  atlas.host.environments.shared-dev.volumeMounts.missing.target = "/home/owner/missing";
};
assert hasFailedMessage "canonical absolute paths" {
  atlas.host.environments.shared-dev.volumeMounts.projects.target =
    lib.mkForce "/home/owner/../escape";
};
assert hasFailedMessage "runtime-managed paths" {
  atlas.host.environments.shared-dev.volumeMounts.projects.target = lib.mkForce "/run/atlas";
};
assert hasFailedMessage "runtime-managed paths" {
  atlas.host.environments.shared-dev.volumeMounts.projects.target = lib.mkForce "/etc/atlas-host";
};
assert hasFailedMessage "runtime-managed paths" {
  atlas.host.environments.shared-dev.volumeMounts.projects.target = lib.mkForce "/mnt";
};
assert hasFailedMessage "overlapping volume mount targets" {
  atlas.host = {
    volumes.second.id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    environments.shared-dev.volumeMounts.second.target = "/home/owner/Projects/nested";
  };
};
assert hasFailedMessage "owner home volume ID" {
  atlas.host.owner.homeVolumeId = lib.mkForce "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
};
assert hasFailedMessage "owner name" {
  atlas.host.owner.name = lib.mkForce "Agent Owner";
};
assert hasFailedMessage "owner name" {
  atlas.host.owner.name = lib.mkForce "root";
};
assert hasFailedMessage "runtime-managed paths" {
  atlas.host.environments.shared-dev.volumeMounts.projects.target =
    lib.mkForce "/home/owner/.config/tool";
};
assert hasFailedMessage "volume IDs must be unique" {
  atlas.host.volumes.second.id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
};
assert hasFailedMessage "reserved ATLAS_" {
  atlas.host.environments.shared-dev.variables.ATLAS_FORGED_IDENTITY = "forged";
};
assert hasFailedMessage "runtime variables" {
  atlas.host.environments.shared-dev.variables.PATH = "/tmp/forged-path";
};
assert hasFailedMessage "runtime variables" {
  atlas.host.environments.shared-dev.variables.GIT_CONFIG_SYSTEM = "/tmp/forged-git-config";
};
assert hasFailedMessage "variable names are invalid" {
  atlas.host.environments.shared-dev.variables."BAD-NAME" = "invalid";
};
assert hasFailedMessage "lowercase slugs" {
  atlas.host.environments.abcdefghijklmnopqrstu = {
    id = "44444444-4444-4444-8444-444444444444";
    uid = 23004;
  };
};
assert hasFailedMessage "RFC 4122 UUIDs" {
  atlas.host.environments.shared-dev.id = lib.mkForce "not-an-environment-id";
};
assert disabledContract.configuration.connectivity.tailscale.adapterEnabled == false;
assert disabledContract.configuration.connectivity.tailscale.sshRequested == false;
assert disabledContract.configuration.connectivity.tailscale.enrollmentMode == "disabled";
assert defaultHost.config.atlas.host.storage.hostRecoveryReserve == false;
assert defaultHost.config.atlas.host.storage.atRestEncryption == "none";
assert encryptedStorageHost.config.atlas.host.storage.hostRecoveryReserve;
assert
  encryptedStorageHost.config.atlas.host.storage.atRestEncryption == "luks2-operator-passphrase";
assert
  installedStorageHost.config.boot.initrd.luks.devices.atlas-crypt.device
  == "/dev/disk/by-uuid/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
assert
  installedStorageHost.config.fileSystems."/".device
  == "/dev/disk/by-uuid/bbbbbbbb-cccc-4ddd-8eee-ffffffffffff";
assert installedStorageHost.config.fileSystems."/boot".device == "/dev/disk/by-uuid/A71A-5001";
assert
  installedStorageHost.config.fileSystems."/var/lib/atlas".device
  == "/dev/disk/by-uuid/cccccccc-dddd-4eee-8fff-aaaaaaaaaaaa";
assert volatileContract.state.persistence == "volatile-live-image";
assert volatileContract.state.storageAdapter == "host-directory";
assert volatileContract.configuration.environmentEntry.adapter == "nixos-incus-directory-v0";
assert
  volatileContract.configuration.environmentEntry.environments.shared-dev.runtime.storage.copyOnWrite
  == false;
assert
  volatileContract.configuration.environmentEntry.environments.shared-dev.runtime.storage.snapshots
  == false;
assert
  !(builtins.hasAttr "seed" volatileContract.configuration.environmentEntry.environments.shared-dev.runtime.storage);
assert
  !(builtins.hasAttr "seedPrepareCommand" volatileContract.configuration.environmentEntry.environments.shared-dev.runtime.storage);
assert !(builtins.hasAttr "atlas-storage-prepare" volatileStateHost.config.systemd.services);
assert
  !(builtins.elem "CAP_SYS_ADMIN" volatileStateHost.config.systemd.services.atlas-manage.serviceConfig.CapabilityBoundingSet);
assert volatileContract.configuration.environmentEntry.composition.rebootPersistentRoots == false;
assert volatileContract.configuration.environmentEntry.composition.durableVolumes == false;
assert
  volatileContract.configuration.environmentEntry.environments.shared-dev.runtime.persistence
  == "until-reset-or-host-reboot";
assert
  volatileContract.configuration.environmentEntry.volumes.projects.durability == "host-volatile";
pkgs.runCommand "atlas-module-evaluation" { } ''
  touch "$out"
''
