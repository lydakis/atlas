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

  isNixStorePath = path: path == "/nix/store" || lib.hasPrefix "/nix/store/" path;
  isSafeAuthKeyPath =
    value:
    let
      path = toString value;
      components = builtins.tail (lib.splitString "/" path);
    in
    builtins.match "^/[-A-Za-z0-9._+]+(/[-A-Za-z0-9._+]+)*$" path != null
    && lib.all (component: component != "." && component != "..") components
    && !(isNixStorePath path);

  dataRoot = toString cfg.dataRoot;

  openSshSettings = config.services.openssh.settings;
  unsafeOpenSshExtraConfig = builtins.any (
    line:
    builtins.match
      "^[[:space:]]*([Mm][Aa][Tt][Cc][Hh]|[Ii][Nn][Cc][Ll][Uu][Dd][Ee])([[:space:]].*)?$"
      line != null
  ) (lib.splitString "\n" config.services.openssh.extraConfig);
  bootstrapOpenSshPolicySatisfied =
    config.services.openssh.enable
    && !config.services.openssh.openFirewall
    && config.services.openssh.ports == [ 22 ]
    && lib.elem 22 config.networking.firewall.allowedTCPPorts
    && (openSshSettings.AllowUsers or null) == [ "root" ]
    && (openSshSettings.AuthenticationMethods or null) == "publickey"
    && (openSshSettings.KbdInteractiveAuthentication or null) == false
    && (openSshSettings.PasswordAuthentication or null) == false
    && (openSshSettings.PermitRootLogin or null) == "prohibit-password"
    && (openSshSettings.PubkeyAuthentication or null) == true
    && (openSshSettings.X11Forwarding or null) == false
    && !unsafeOpenSshExtraConfig;

  stateRoot = {
    group = "root";
    mode = "0711";
    owner = "root";
  };

  stateDirectoryLayout = {
    audit = {
      group = "atlas-control";
      mode = "0750";
      owner = "atlas-control";
    };
    "browser-profiles" = {
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

  intendedPrimitives = [
    "host"
    "environment"
    "volume"
    "grant"
    "surface"
    "route"
  ];

  mkTmpfilesRule =
    path: metadata: "d ${path} ${metadata.mode} ${metadata.owner} ${metadata.group} - -";

  atlasEnroll = pkgs.writeShellApplication {
    name = "atlas-enroll";
    runtimeInputs = [ pkgs.tailscale ];
    text = ''
      usage() {
        echo "Usage: sudo atlas-enroll"
        echo "Interactively enroll this host in Tailscale${lib.optionalString cfg.tailscale.ssh " and enable private SSH"}."
      }

      if [ "$#" -eq 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
        usage
        exit 0
      fi

      if [ "$#" -ne 0 ]; then
        usage >&2
        exit 2
      fi

      if [ "$EUID" -ne 0 ]; then
        echo "atlas-enroll must run as root; use sudo atlas-enroll" >&2
        exit 1
      fi

      exec tailscale up --qr ${lib.optionalString cfg.tailscale.ssh "--ssh"}
    '';
  };
in
{
  imports = [ ./atlas-environments.nix ];

  options.atlas.host = {
    enable = mkEnableOption "the Atlas static host contract";

    dataRoot = mkOption {
      type = types.addCheck types.externalPath (value: toString value == "/var/lib/atlas");
      default = "/var/lib/atlas";
      description = ''
        Fixed v0 mount point for mutable Atlas state. Deployments that use a
        separate disk or volume must mount it at /var/lib/atlas. The path must
        be preserved independently of a system generation.
      '';
    };

    dataRootPersistence = mkOption {
      type = types.enum [
        "reboot-persistent"
        "volatile-live-image"
      ];
      default = "reboot-persistent";
      description = ''
        Deployment fact describing whether /var/lib/atlas survives host reboot.
        Live artifacts must report volatile storage rather than inheriting the
        installed-host persistence guarantee.
      '';
    };

    tailscale.enable = mkEnableOption "the Tailscale connectivity adapter";

    tailscale.authKeyFile = mkOption {
      type = types.nullOr (types.addCheck types.externalPath isSafeAuthKeyPath);
      default = null;
      example = literalExpression ''"/run/secrets/atlas-tailscale-auth-key"'';
      description = ''
        Optional external runtime path containing a short-lived Tailscale
        enrollment key. Nix path values, non-canonical paths, and Nix store
        paths are rejected. The resolved runtime path is also checked before
        enrollment. When omitted, the operator enrolls interactively with
        `sudo atlas-enroll`.
      '';
    };

    tailscale.ssh = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable Tailscale SSH during enrollment. Authorization remains governed
        by the operator's tailnet policy and local Atlas account boundaries.
      '';
    };

    bootstrapOpenSsh.enable = mkEnableOption ''
      a temporary key-only OpenSSH bootstrap listener
    '';

    contract = mkOption {
      readOnly = true;
      type = types.attrs;
      description = "Machine-readable facts guaranteed by this module.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion =
          cfg.tailscale.authKeyFile == null || !(isNixStorePath (toString cfg.tailscale.authKeyFile));
        message = "atlas.host.tailscale.authKeyFile must be a runtime secret outside the Nix store";
      }
      {
        assertion = cfg.tailscale.authKeyFile == null || cfg.tailscale.enable;
        message = "atlas.host.tailscale.enable must be true when authKeyFile is configured";
      }
      {
        assertion = cfg.bootstrapOpenSsh.enable == config.services.openssh.enable;
        message = "atlas.host.bootstrapOpenSsh.enable must match the effective OpenSSH service state";
      }
      {
        assertion = !cfg.bootstrapOpenSsh.enable || bootstrapOpenSshPolicySatisfied;
        message = "atlas.host bootstrap OpenSSH must preserve the exact root public-key-only policy";
      }
      {
        assertion = !cfg.bootstrapOpenSsh.enable || cfg.tailscale.enable;
        message = "atlas.host.tailscale.enable must be true when the OpenSSH bootstrap listener is enabled";
      }
    ];

    atlas.host.contract = {
      version = 7;
      intent.primitives = intendedPrimitives;
      implementation.primitives = [
        "host"
        "environment"
        "volume"
      ];
      state = {
        root = dataRoot;
        persistence = cfg.dataRootPersistence;
        storageAdapter = cfg.storage.adapter;
        rootMode = stateRoot.mode;
        rootOwner = stateRoot.owner;
        rootGroup = stateRoot.group;
        directories = stateDirectoryLayout;
      };
      configuration = {
        connectivity = {
          openSshConfigured = config.services.openssh.enable;
          openSshMode =
            if !config.services.openssh.enable then
              "disabled"
            else if bootstrapOpenSshPolicySatisfied then
              "bootstrap-root-public-key-only"
            else
              "invalid";
          tailscale = {
            adapterEnabled = cfg.tailscale.enable;
            sshRequested = cfg.tailscale.enable && cfg.tailscale.ssh;
            enrollmentMode =
              if !cfg.tailscale.enable then
                "disabled"
              else if cfg.tailscale.authKeyFile == null then
                "interactive"
              else
                "auth-key-file";
          };
        };
        nix = {
          allowedUsers = [ "root" ];
          trustedUsers = [ "root" ];
        };
        resourceSlices = {
          control = "atlas-control.slice";
          environments = "atlas-environments.slice";
        };
        environmentEntry = cfg.environmentContract;
      };
    };

    environment.etc."atlas/host-contract.json".text = builtins.toJSON cfg.contract;

    environment.systemPackages =
      with pkgs;
      [
        curl
        git
        jq
        tmux
        util-linux
      ]
      ++ lib.optional cfg.tailscale.enable atlasEnroll;

    networking.firewall.enable = true;
    networking.firewall.allowedTCPPorts = lib.optionals cfg.bootstrapOpenSsh.enable [ 22 ];

    nix.settings = {
      allowed-users = lib.mkForce [ "root" ];
      experimental-features = [
        "flakes"
        "nix-command"
      ];
      sandbox = lib.mkForce true;
      trusted-users = lib.mkForce [ "root" ];
    };

    services.tailscale = mkIf cfg.tailscale.enable {
      enable = true;
      openFirewall = true;
      authKeyFile = cfg.tailscale.authKeyFile;
      extraUpFlags = lib.optionals cfg.tailscale.ssh [ "--ssh" ];
    };

    services.openssh = mkIf cfg.bootstrapOpenSsh.enable {
      enable = true;
      openFirewall = false;
      settings = {
        AllowUsers = [ "root" ];
        AuthenticationMethods = "publickey";
        KbdInteractiveAuthentication = false;
        PasswordAuthentication = false;
        PermitRootLogin = "prohibit-password";
        PubkeyAuthentication = true;
        X11Forwarding = false;
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
          test -d ${lib.escapeShellArg dataRoot}
          test "$(stat -c %a ${lib.escapeShellArg dataRoot})" = ${lib.escapeShellArg (lib.removePrefix "0" stateRoot.mode)}
          test "$(stat -c %U ${lib.escapeShellArg dataRoot})" = ${lib.escapeShellArg stateRoot.owner}
          test "$(stat -c %G ${lib.escapeShellArg dataRoot})" = ${lib.escapeShellArg stateRoot.group}
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (directory: metadata: ''
              test -d ${lib.escapeShellArg "${dataRoot}/${directory}"}
              test "$(stat -c %a ${lib.escapeShellArg "${dataRoot}/${directory}"})" = ${lib.escapeShellArg (lib.removePrefix "0" metadata.mode)}
              test "$(stat -c %U ${lib.escapeShellArg "${dataRoot}/${directory}"})" = ${lib.escapeShellArg metadata.owner}
              test "$(stat -c %G ${lib.escapeShellArg "${dataRoot}/${directory}"})" = ${lib.escapeShellArg metadata.group}
            '') stateDirectoryLayout
          )}
        '';
      };

      services.tailscaled-autoconnect = mkIf (cfg.tailscale.enable && cfg.tailscale.authKeyFile != null) {
        preStart = ''
          auth_key_path=${lib.escapeShellArg (toString cfg.tailscale.authKeyFile)}
          if [ ! -f "$auth_key_path" ]; then
            echo "Atlas Tailscale auth-key path is not a regular file: $auth_key_path" >&2
            exit 1
          fi
          resolved="$(${pkgs.coreutils}/bin/readlink -f -- "$auth_key_path")"
          case "$resolved" in
            /nix/store|/nix/store/*)
              echo "Atlas Tailscale auth-key path resolves inside the Nix store" >&2
              exit 1
              ;;
          esac
        '';
      };

      slices = {
        atlas-control.sliceConfig = {
          CPUWeight = 1000;
          IOWeight = 1000;
          MemoryLow = "256M";
          TasksMax = 2048;
        };
        atlas-environments.sliceConfig = {
          CPUWeight = 100;
          IOWeight = 100;
          TasksMax = 32768;
        };
      };

      targets.atlas-host = {
        description = "Atlas host contract is ready";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ] ++ lib.optional cfg.tailscale.enable "tailscaled.service";
        after = [ "network-online.target" ] ++ lib.optional cfg.tailscale.enable "tailscaled.service";
      };

      tmpfiles.rules = [
        (mkTmpfilesRule dataRoot stateRoot)
      ]
      ++ lib.mapAttrsToList (
        directory: metadata: mkTmpfilesRule "${dataRoot}/${directory}" metadata
      ) stateDirectoryLayout;
    };

    users = {
      mutableUsers = false;

      groups.atlas-control = { };

      users = {
        atlas-control = {
          isSystemUser = true;
          group = "atlas-control";
          home = "${dataRoot}/control";
        };

        atlas-operator = {
          isNormalUser = true;
          extraGroups = [ "wheel" ];
          hashedPassword = "!";
        };
      };
    };
  };
}
