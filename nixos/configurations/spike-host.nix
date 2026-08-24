{
  lib,
  pkgs,
  ...
}:
let
  mkSpikeWorkload =
    name: response:
    let
      site = pkgs.writeTextDir "index.html" response;
    in
    {
      description = "Atlas isolated spike workload ${name}";
      wantedBy = [ "atlas-host.target" ];
      after = [ "atlas-host-contract.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python -m http.server 3000 --bind 127.0.0.1 --directory ${site}";
        Slice = "atlas-workloads.slice";
        DynamicUser = true;
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
  atlas.host.enable = true;

  # The spike deliberately has no ambient login credential. Remote access is
  # enabled only when an operator public key is supplied to the host module.
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
    atlas-spike-alpha = mkSpikeWorkload "alpha" "atlas workload alpha\n";
    atlas-spike-beta = mkSpikeWorkload "beta" "atlas workload beta\n";
  };
}
