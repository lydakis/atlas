{
  atlasModule,
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
assert defaultContract.version == 5;
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
assert defaultContract.state.rootMode == "0711";
assert defaultContract.state.directories == expectedStateDirectories;
assert defaultContract.configuration.connectivity.openSshConfigured == false;
assert defaultContract.configuration.connectivity.tailscale.adapterEnabled == true;
assert defaultContract.configuration.connectivity.tailscale.sshRequested == true;
assert defaultContract.configuration.connectivity.tailscale.enrollmentMode == "interactive";
assert defaultContract.configuration.environmentEntry.version == 3;
assert defaultContract.configuration.environmentEntry.adapter == "nixos-nspawn-service-v0";
assert defaultContract.configuration.environmentEntry.composition.declarative == true;
assert defaultContract.configuration.environmentEntry.composition.runtimeCreation == false;
assert defaultContract.configuration.environmentEntry.composition.disposableRoots == true;
assert defaultContract.configuration.environmentEntry.composition.durableVolumes == true;
assert defaultContract.configuration.environmentEntry.composition.persistentInstances == true;
assert defaultContract.configuration.environmentEntry.composition.concurrentEntry == true;
assert
  defaultContract.configuration.environmentEntry.volumes.projects == {
    durability = "host-durable";
    hostPath = "/var/lib/atlas/volumes/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/data";
    id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    name = "projects";
    owner = "operator";
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
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.volumes == [
    {
      access = "read-write";
      id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      name = "projects";
      target = "/home/agent/work";
    }
  ];
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.lifecycle
  == "disposable";
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.backend
  == "systemd-nspawn-service";
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.readyHostPath
  == "/run/atlas/environments/11111111-1111-4111-8111-111111111111/rootfs.ready";
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.runtime.storageMax == "1G";
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.process.serviceUnit
  == "atlas-environment-shared\\x2ddev.service";
assert
  defaultContract.configuration.environmentEntry.environments.shared-dev.process.cgroupPrefix
  == "/atlas.slice/atlas-environments.slice/atlas-environments-shared\\x2ddev.slice/atlas-environment-shared\\x2ddev.service";
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
assert defaultHost.config.systemd.sockets.atlas-manage.socketConfig.SocketMode == "0600";
assert
  defaultHost.config.systemd.services."atlas-environment-shared\\x2ddev".serviceConfig.Type
  == "notify";
assert
  defaultHost.config.systemd.services."atlas-environment-shared\\x2ddev".serviceConfig.Slice
  == "atlas-environments-shared\\x2ddev.slice";
assert builtins.any (
  mount:
  mount.where == "/run/atlas/environments/11111111-1111-4111-8111-111111111111"
  && lib.hasInfix "size=1G" mount.options
) defaultHost.config.systemd.mounts;
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
  atlas.host.environments.shared-dev.volumeMounts.missing.target = "/home/agent/missing";
};
assert hasFailedMessage "canonical absolute paths" {
  atlas.host.environments.shared-dev.volumeMounts.projects.target =
    lib.mkForce "/home/agent/../escape";
};
assert hasFailedMessage "runtime-managed paths" {
  atlas.host.environments.shared-dev.volumeMounts.projects.target = lib.mkForce "/run/atlas";
};
assert hasFailedMessage "overlapping volume mount targets" {
  atlas.host = {
    volumes.second.id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    environments.shared-dev.volumeMounts.second.target = "/home/agent/work/nested";
  };
};
assert hasFailedMessage "runtimeSize" {
  atlas.host.environments.shared-dev.runtimeSize = "unbounded";
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
pkgs.runCommand "atlas-module-evaluation" { } ''
  touch "$out"
''
