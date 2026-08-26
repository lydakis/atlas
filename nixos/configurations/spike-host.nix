{
  lib,
  pkgs,
  ...
}:
let
  mkSpikeEnvironment =
    name: response:
    let
      site = pkgs.writeTextDir "index.html" response;
    in
    {
      description = "Atlas isolated spike environment ${name}";
      wantedBy = [ "atlas-host.target" ];
      after = [ "atlas-host-contract.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python -m http.server 3000 --bind 127.0.0.1 --directory ${site}";
        Slice = "atlas-environments.slice";
        DynamicUser = true;
        StateDirectory = "atlas/environments/spike-${name}";
        StateDirectoryMode = "0700";
        UMask = "0077";

        AmbientCapabilities = "";
        CapabilityBoundingSet = "";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateNetwork = true;
        PrivateTmp = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        RestrictSUIDSGID = true;
      };
    };
in
{
  atlas.host = {
    enable = true;
    tailscale.enable = true;
  };

  # The spike deliberately has no ambient login credential. Remote access is
  # enabled only after interactive or runtime-secret Tailscale enrollment.
  users.allowNoPasswordLogin = true;

  documentation.enable = false;

  networking = {
    hostName = "atlas-spike";
    useDHCP = lib.mkDefault true;
  };

  system = {
    stateVersion = "26.05";
    nixos.tags = [ "atlas-spike" ];
  };

  environment.etc."atlas-spike-generation".text = "baseline\n";

  specialisation.atlas-updated.configuration = {
    system.nixos.tags = [ "atlas-spike-update" ];
    environment.etc."atlas-spike-generation".text = lib.mkForce "updated\n";
  };

  systemd.services = {
    atlas-spike-alpha = mkSpikeEnvironment "alpha" "atlas environment alpha\n";
    atlas-spike-beta = mkSpikeEnvironment "beta" "atlas environment beta\n";
  };
}
