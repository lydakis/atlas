{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.atlas.host;
  inherit (lib)
    literalExpression
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  stateDirectories = [
    "audit"
    "browser"
    "caches"
    "credentials"
    "workspaces"
  ];
in
{
  options.atlas.host = {
    enable = mkEnableOption "the Atlas static host contract";

    dataRoot = mkOption {
      type = types.path;
      default = "/var/lib/atlas";
      description = ''
        Mutable Atlas state. This path deliberately sits outside the Nix store
        and must be preserved independently of a system generation.
      '';
    };

    operatorAuthorizedKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = literalExpression ''[ "ssh-ed25519 AAAA... operator" ]'';
      description = ''
        Public keys allowed to enter the recovery operator account. SSH stays
        disabled when this list is empty.
      '';
    };

    contract = mkOption {
      readOnly = true;
      type = types.attrs;
      description = "Machine-readable facts guaranteed by this module.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/" (toString cfg.dataRoot);
        message = "atlas.host.dataRoot must be an absolute path";
      }
      {
        assertion = (toString cfg.dataRoot) != "/nix" && !(lib.hasPrefix "/nix/" (toString cfg.dataRoot));
        message = "atlas.host.dataRoot must not be inside the Nix store";
      }
    ];

    atlas.host.contract = {
      version = 1;
      dataRoot = toString cfg.dataRoot;
      stateDirectories = stateDirectories;
      controlSlice = "atlas-control.slice";
      workloadSlice = "atlas-workloads.slice";
      nixAllowedUsers = [ "root" ];
      nixTrustedUsers = [ "root" ];
      remoteOperatorEnabled = cfg.operatorAuthorizedKeys != [ ];
    };

    environment.etc."atlas/host-contract.json".text = builtins.toJSON cfg.contract;

    environment.systemPackages = with pkgs; [
      curl
      git
      jq
      tmux
      util-linux
    ];

    networking.firewall = {
      enable = true;
      allowedTCPPorts = lib.optionals (cfg.operatorAuthorizedKeys != [ ]) [ 22 ];
    };

    nix.settings = {
      allowed-users = lib.mkForce [ "root" ];
      experimental-features = [
        "flakes"
        "nix-command"
      ];
      sandbox = lib.mkForce true;
      trusted-users = lib.mkForce [ "root" ];
    };

    services.openssh = mkIf (cfg.operatorAuthorizedKeys != [ ]) {
      enable = true;
      settings = {
        KbdInteractiveAuthentication = false;
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    security.sudo.wheelNeedsPassword = false;

    systemd = {
      oomd.enable = true;

      services.atlas-host-contract = {
        description = "Validate the Atlas host state boundary";
        requiredBy = [ "atlas-host.target" ];
        before = [ "atlas-host.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Slice = "atlas-control.slice";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
        };
        script = ''
          set -eu
          test -d ${lib.escapeShellArg (toString cfg.dataRoot)}
          ${lib.concatMapStringsSep "\n" (directory: ''
            test -d ${lib.escapeShellArg "${toString cfg.dataRoot}/${directory}"}
          '') stateDirectories}
        '';
      };

      slices = {
        atlas-control.sliceConfig = {
          CPUWeight = 1000;
          IOWeight = 1000;
          MemoryLow = "256M";
          TasksMax = 2048;
        };
        atlas-workloads.sliceConfig = {
          CPUWeight = 100;
          IOWeight = 100;
          TasksMax = 32768;
        };
      };

      targets.atlas-host = {
        description = "Atlas host contract is ready";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
      };

      tmpfiles.rules = [
        "d ${toString cfg.dataRoot} 0750 atlas-control atlas-control - -"
        "d ${toString cfg.dataRoot}/audit 0750 atlas-control atlas-control - -"
        "d ${toString cfg.dataRoot}/browser 0711 root root - -"
        "d ${toString cfg.dataRoot}/caches 0711 root root - -"
        "d ${toString cfg.dataRoot}/credentials 0700 atlas-control atlas-control - -"
        "d ${toString cfg.dataRoot}/workspaces 0711 root root - -"
      ];
    };

    users = {
      mutableUsers = false;

      groups.atlas-control = { };

      users = {
        atlas-control = {
          isSystemUser = true;
          group = "atlas-control";
          home = "${toString cfg.dataRoot}/control";
        };

        atlas-operator = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
          hashedPassword = "!";
          openssh.authorizedKeys.keys = cfg.operatorAuthorizedKeys;
        };
      };
    };
  };
}
