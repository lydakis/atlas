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
assert lib.hasInfix ''cat ${runtimeSecretPath}'' runtimeSecretScript;
assert !(lib.hasInfix "/nix/store" runtimeSecretScript);
assert defaultContract.version == 3;
assert defaultContract.intent.primitives == [
  "host"
  "environment"
  "grant"
  "surface"
  "route"
];
assert defaultContract.implementation.primitives == [ "host" ];
assert defaultContract.state.root == "/var/lib/atlas";
assert defaultContract.state.rootMode == "0711";
assert defaultContract.state.directories == expectedStateDirectories;
assert defaultContract.configuration.connectivity.openSshConfigured == false;
assert defaultContract.configuration.connectivity.tailscale.adapterEnabled == true;
assert defaultContract.configuration.connectivity.tailscale.sshRequested == true;
assert defaultContract.configuration.connectivity.tailscale.enrollmentMode == "interactive";
assert disabledContract.configuration.connectivity.tailscale.adapterEnabled == false;
assert disabledContract.configuration.connectivity.tailscale.sshRequested == false;
assert disabledContract.configuration.connectivity.tailscale.enrollmentMode == "disabled";
pkgs.runCommand "atlas-module-evaluation" { } ''
  touch "$out"
''
