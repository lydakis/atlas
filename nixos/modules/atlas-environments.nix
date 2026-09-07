{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.atlas.host;
  incusInventory = "${pkgs.python3}/bin/python3 -I ${../../src/atlas/lifecycle.py} --incus ${pkgs.incus-lts}/bin/incus";
  gitIni = pkgs.formats.gitIni { };
  yaml = pkgs.formats.yaml { };
  inherit (lib)
    concatMap
    concatMapStringsSep
    filter
    foldl'
    hasAttr
    hasPrefix
    length
    mapAttrs
    mapAttrs'
    mapAttrsToList
    mkIf
    mkOption
    nameValuePair
    types
    unique
    ;

  environmentNames = builtins.attrNames cfg.environments;
  incusDeclaredInstances = pkgs.writeText "atlas-incus-declared-instances" (
    concatMapStringsSep "\n" (name: "atlas-${name}") environmentNames
  );
  # No probing or order-dependent allocation: a collision rejects the declaration
  # instead of changing another environment's address. Reserve the gateway range.
  environmentIpv4ByName = mapAttrs (
    _name: environment:
    let
      digits = lib.stringToCharacters "0123456789abcdef";
      hex = builtins.listToAttrs (lib.imap0 (index: digit: nameValuePair digit index) digits);
      hash = builtins.substring 0 8 (builtins.hashString "sha256" environment.id);
      value = lib.foldl' (acc: digit: acc * 16 + hex.${digit}) 0 (lib.stringToCharacters hash);
      slot = lib.mod value (254 * 254);
    in
    "10.211.${toString (1 + builtins.div slot 254)}.${toString (1 + lib.mod slot 254)}"
  ) cfg.environments;
  layerNames = builtins.attrNames cfg.environmentLayers;
  volumeNames = builtins.attrNames cfg.volumes;

  loginUser = name: "atlas-${name}";
  loginHome = environment: "/run/atlas/entry-users/${environment.id}";
  environmentLock = environment: "/run/atlas/locks/${environment.id}.lock";
  guestContractRoot = "/run/atlas/guest-contract";
  volumePath = volume: "${toString cfg.dataRoot}/volumes/${volume.id}/data";
  ownerHome = "/home/${cfg.owner.name}";
  ownerHomeVolume = {
    id = cfg.owner.homeVolumeId;
  };
  ownerHomePath = volumePath ownerHomeVolume;
  resettableHomePaths = [
    ".cache"
    ".config"
    ".local/bin"
    ".local/state"
  ];
  dataRootPersistent = cfg.dataRootPersistence == "reboot-persistent";
  btrfsStorage = cfg.storage.adapter == "btrfs-subvolume";
  escapedSliceSegment = name: lib.replaceStrings [ "-" ] [ "\\x2d" ] name;
  environmentServiceName = name: "atlas-environment-${escapedSliceSegment name}";
  environmentControlServiceName = name: "atlas-environment-control-${escapedSliceSegment name}";
  environmentCgroupPrefix = name: "/lxc.payload.atlas-${name}";

  ubuntuArchitecture = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";
  incusImageVersion = "20260829_07:42";
  incusImageMetadataHash =
    if pkgs.stdenv.hostPlatform.isAarch64 then
      "sha256-hNvdWu9fPSk807Zw7+rN8MSGxrH3IdGJ3mJMrHMhumw="
    else
      "sha256-ZgzuAjoW2aSydSlxN95JUs45CvjioDKlwfmUi8elo9k=";
  incusImageRootHash =
    if pkgs.stdenv.hostPlatform.isAarch64 then
      "sha256-gj3087s49oN+/oI30Hsr2OYlazy0QTStvTRNtxEPfQ4="
    else
      "sha256-STGVZi/M3l7a9aLd0Ft6rwHMiM9KedBQRjfIDDvz9iA=";
  incusImageContentId = builtins.hashString "sha256" (
    builtins.toJSON {
      metadata = incusImageMetadataHash;
      root = incusImageRootHash;
    }
  );
  incusImageAlias = "atlas-ubuntu-${builtins.substring 0 12 incusImageContentId}";
  # Upstream daily builds expire. Retain the exact pinned bytes in Atlas's
  # image release; never replace assets under an existing release tag.
  incusImageMirror = "https://github.com/lydakis/atlas/releases/download/ubuntu-noble-20260829-0742";
  incusImageMetadata = pkgs.fetchurl {
    name = "incus.tar.xz";
    url = "${incusImageMirror}/${ubuntuArchitecture}-incus.tar.xz";
    hash = incusImageMetadataHash;
  };
  incusImageRoot = pkgs.fetchurl {
    name = "rootfs.squashfs";
    url = "${incusImageMirror}/${ubuntuArchitecture}-rootfs.squashfs";
    hash = incusImageRootHash;
  };
  baseImageRecord = {
    distribution = "ubuntu";
    release = "24.04";
    build = builtins.substring 0 8 incusImageVersion;
    architecture = ubuntuArchitecture;
    source = "linuxcontainers-incus-image";
    contentId = incusImageContentId;
  };
  environmentLayoutId =
    name: environment:
    builtins.hashString "sha256" (
      builtins.toJSON {
        version = 1;
        baseImage = baseImageRecord // {
          alias = incusImageAlias;
        };
        owner = {
          inherit (cfg.owner) name uid;
          homeVolumeId = if environment.ownerHome then cfg.owner.homeVolumeId else null;
          elevation = "passwordless-environment-sudo";
        };
        durableOwnerHome = environment.ownerHome;
        resettablePaths = if environment.ownerHome then resettableHomePaths else [ ];
        network = {
          address = environmentIpv4ByName.${name};
          acl = "atlas-private";
        };
        runtimeSurfaces = {
          nixStore = "/nix/store";
          contract = "/etc/atlas-host/control-contract.json";
          control = "/mnt/atlas-control.sock";
        };
        startup = "atlas-systemd-service";
        volumes = mapAttrs (volumeName: mount: {
          inherit (mount) access target;
          inherit (cfg.volumes.${volumeName}) id;
          hostPath = volumePath cfg.volumes.${volumeName};
        }) (lib.filterAttrs (volumeName: _mount: hasAttr volumeName cfg.volumes) environment.volumeMounts);
      }
    );

  effectiveVariables =
    environment:
    foldl' (
      variables: layer:
      if hasAttr layer cfg.environmentLayers then
        variables // cfg.environmentLayers.${layer}.variables
      else
        variables
    ) { } environment.layers
    // environment.variables;

  effectivePackages =
    environment:
    foldl' (
      packages: layer:
      if hasAttr layer cfg.environmentLayers then
        packages // cfg.environmentLayers.${layer}.packages
      else
        packages
    ) { } environment.layers
    // environment.packages;

  effectiveGitConfig =
    environment:
    lib.recursiveUpdate (foldl' (
      gitConfig: layer:
      if hasAttr layer cfg.environmentLayers then
        lib.recursiveUpdate gitConfig cfg.environmentLayers.${layer}.git.config
      else
        gitConfig
    ) { } environment.layers) environment.git.config;

  effectivePackageNames =
    environment: mapAttrs (_alias: package: lib.getName package) (effectivePackages environment);

  gitConfigFiles = mapAttrs (
    name: environment: gitIni.generate "atlas-git-${name}.config" (effectiveGitConfig environment)
  ) cfg.environments;

  volumeRecord = name: volume: {
    inherit (volume) id;
    inherit name;
    hostPath = volumePath volume;
    durability = if dataRootPersistent then "host-durable" else "host-volatile";
  };
  volumeRecords = mapAttrs volumeRecord cfg.volumes;

  ownerRecord = {
    name = cfg.owner.name;
    uid = cfg.owner.uid;
    home = ownerHome;
    homeStorage = {
      id = cfg.owner.homeVolumeId;
      hostPath = ownerHomePath;
      durability = if dataRootPersistent then "host-durable" else "host-volatile";
    };
  };

  environmentVolumeRecords =
    environment:
    mapAttrsToList (name: mount: {
      inherit (mount) access target;
      inherit name;
      id = cfg.volumes.${name}.id;
      hostPath = volumePath cfg.volumes.${name};
    }) (lib.filterAttrs (name: _mount: hasAttr name cfg.volumes) environment.volumeMounts);

  environmentRecord = name: environment: {
    inherit (environment) id uid;
    inherit name;
    home = ownerHome;
    user = {
      name = cfg.owner.name;
      uid = cfg.owner.uid;
      elevation = "passwordless-environment-sudo";
    };
    homeComposition =
      if environment.ownerHome then
        {
          durable = true;
          durableHostPath = ownerHomePath;
          resettablePaths = resettableHomePaths;
        }
      else
        {
          durable = false;
          resettablePaths = [ ];
        };
    variables = effectiveVariables environment;
    packages = effectivePackageNames environment;
    git.config = effectiveGitConfig environment;
    network = {
      mode = "private-nat";
      status = "experimental";
      ipv4Address = environmentIpv4ByName.${name};
    };
    runtime = {
      backend = "incus-container";
      lifecycle = "resettable";
      layoutId = environmentLayoutId name environment;
      persistence = if dataRootPersistent then "until-explicit-reset" else "until-reset-or-host-reboot";
      resettable = true;
      storage = {
        adapter = "incus-${cfg.storage.adapter}-pool";
        copyOnWrite = btrfsStorage;
        snapshots = btrfsStorage;
      };
      baseImage = baseImageRecord;
      instance = {
        name = "atlas-${name}";
        resetCommand = "${incusResetCommands.${name}}/bin/atlas-incus-reset-${name}";
        verifyCommand = "${incusVerifyCommands.${name}}/bin/atlas-incus-verify-${name}";
      };
    };
    process = {
      cgroupPrefix = environmentCgroupPrefix name;
      serviceUnit = "incus.service";
      sliceUnit = "system.slice";
    };
    volumes = environmentVolumeRecords environment;
    entry = {
      adapter = "fixed-login-to-persistent-incus";
      loginUser = loginUser name;
      loginUid = environment.uid;
    };
  };

  environmentRecords = mapAttrs environmentRecord cfg.environments;
  environmentByUid = builtins.listToAttrs (
    mapAttrsToList (name: environment: nameValuePair (toString environment.uid) name) cfg.environments
  );
  environmentByCgroupPrefix = builtins.listToAttrs (
    map (name: nameValuePair (environmentCgroupPrefix name) name) environmentNames
  );

  doctor = {
    status = "experimental";
    adapter = "nixos-incus-${if btrfsStorage then "btrfs" else "directory"}-v0";
    composition = {
      declarative = true;
      named = true;
      reusableLayers = true;
      runtimeCreation = false;
      ephemeralRuntimeCreation = false;
      packages = true;
      managedGitConfig = true;
      disposableRoots = false;
      resettableRoots = true;
      rebootPersistentRoots = dataRootPersistent;
      durableVolumes = dataRootPersistent;
      durableOwnerHome = dataRootPersistent;
      resettableHomePaths = true;
      persistentInstances = true;
      concurrentEntry = true;
    };
    identity = {
      source = "unix-peer-credentials-or-host-bound-environment-listener";
      callerAuthoredIdentityAccepted = false;
    };
    rootIsolation = {
      mode = "incus-isolated-idmap";
      status = "experimental";
      hostRootShared = false;
      packageManager = "apt";
    };
    storage = {
      mode =
        if btrfsStorage then
          "btrfs-copy-on-write-with-explicit-volumes"
        else
          "elastic-host-directory-with-explicit-volumes";
      status = if btrfsStorage then "experimental" else "degraded";
      bounded = false;
      copyOnWrite = btrfsStorage;
      snapshots = btrfsStorage;
      rollback = btrfsStorage;
      hostRecoveryReserve = cfg.storage.hostRecoveryReserve;
      rootPersistsAcrossReboot = dataRootPersistent;
      resettable = true;
      atRestEncryption = {
        mode = cfg.storage.atRestEncryption;
        status = if cfg.storage.atRestEncryption == "none" then "degraded" else "experimental";
      };
    };
    networkIsolation = {
      mode = "incus-bridge-nat-acl";
      status = "experimental";
    };
    toolIsolation = {
      mode = "container-rootfs-plus-read-only-nix-store";
      status = "degraded";
    };
    secrets = {
      environmentVariablesAreSecret = false;
      grantsImplemented = false;
    };
  };

  controlContract = {
    inherit doctor environmentByCgroupPrefix environmentByUid;
    environments = environmentRecords;
  };
  privateNetworkDestinations = [
    "10.0.0.0/8"
    "100.64.0.0/10"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
  ];
  incusPrivateAcl = {
    config = { };
    description = "Atlas private environment egress policy";
    ingress = [ ];
    egress = [
      {
        action = "allow";
        destination = "10.211.0.1";
        protocol = "udp";
        destination_port = "53";
        state = "enabled";
      }
      {
        action = "allow";
        destination = "10.211.0.1";
        protocol = "tcp";
        destination_port = "53";
        state = "enabled";
      }
    ]
    ++ map (destination: {
      action = "reject";
      inherit destination;
      state = "enabled";
    }) privateNetworkDestinations
    ++ [
      {
        action = "allow";
        state = "enabled";
      }
    ];
  };
  incusPrivateAclFile = yaml.generate "atlas-private-acl.yaml" incusPrivateAcl;
  controlContractFile = pkgs.writeText "atlas-control-contract.json" (
    builtins.toJSON controlContract
  );
  environmentConfigFiles = mapAttrs (
    name: _environment:
    pkgs.writeText "atlas-environment-${name}.json" (builtins.toJSON environmentRecords.${name})
  ) cfg.environments;

  atlasControl = pkgs.writeShellApplication {
    name = "atlas";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      export PYTHONPATH=${../../src}
      exec python3 -P -m atlas "$@"
    '';
  };

  environmentShells = mapAttrs (
    name: _environment:
    pkgs.writeShellScript "atlas-environment-shell-${name}" ''
      exec ${pkgs.bashInteractive}/bin/bash --noprofile --norc "$@"
    ''
  ) cfg.environments;

  environmentVariables =
    name: environment:
    let
      environmentShell = environmentShells.${name};
      toolPath = lib.makeBinPath (
        [
          atlasControl
          pkgs.bashInteractive
          pkgs.coreutils
          pkgs.gnugrep
        ]
        ++ builtins.attrValues (effectivePackages environment)
      );
    in
    effectiveVariables environment
    // {
      ATLAS_CONTROL_SOCKET = "/mnt/atlas-control.sock";
      ATLAS_ENVIRONMENT_ID = environment.id;
      ATLAS_ENVIRONMENT_NAME = name;
      GIT_CONFIG_GLOBAL = "${ownerHome}/.config/git/config";
      GIT_CONFIG_SYSTEM = toString gitConfigFiles.${name};
      HOME = ownerHome;
      LOGNAME = cfg.owner.name;
      PATH = "${ownerHome}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${toolPath}";
      SHELL = toString environmentShell;
      USER = cfg.owner.name;
    };

  environmentAssignmentLines =
    name: environment:
    let
      variables = environmentVariables name environment;
    in
    concatMapStringsSep " \\\n" (
      variable: "          ${lib.escapeShellArg "${variable}=${variables.${variable}}"}"
    ) (builtins.attrNames variables);

  incusGuestProvisioners = mapAttrs (
    name: environment:
    let
      layoutId = environmentLayoutId name environment;
      resettableHome = lib.optionalString (!environment.ownerHome) ''
        install -d -m 0700 -o ${toString cfg.owner.uid} -g ${toString cfg.owner.uid} \
          ${lib.escapeShellArg ownerHome}
      '';
    in
    pkgs.writeShellScript "atlas-incus-provision-${name}" ''
      set -eu
      existing_user="$(getent passwd ${toString cfg.owner.uid} | cut -d: -f1 || true)"
      if [ -n "$existing_user" ] && [ "$existing_user" != ${lib.escapeShellArg cfg.owner.name} ]; then
        userdel --force "$existing_user"
      fi
      named_user_uid="$(id -u ${lib.escapeShellArg cfg.owner.name} 2>/dev/null || true)"
      if [ -n "$named_user_uid" ] && [ "$named_user_uid" != ${toString cfg.owner.uid} ]; then
        userdel --force ${lib.escapeShellArg cfg.owner.name}
      fi
      existing_group="$(getent group ${toString cfg.owner.uid} | cut -d: -f1 || true)"
      if [ -n "$existing_group" ] && [ "$existing_group" != ${lib.escapeShellArg cfg.owner.name} ]; then
        groupdel "$existing_group"
      fi
      named_group_gid="$(getent group ${lib.escapeShellArg cfg.owner.name} | cut -d: -f3 || true)"
      if [ -n "$named_group_gid" ] && [ "$named_group_gid" != ${toString cfg.owner.uid} ]; then
        groupdel ${lib.escapeShellArg cfg.owner.name}
      fi
      if ! getent group ${lib.escapeShellArg cfg.owner.name} >/dev/null; then
        groupadd --gid ${toString cfg.owner.uid} ${lib.escapeShellArg cfg.owner.name}
      fi
      if ! getent passwd ${lib.escapeShellArg cfg.owner.name} >/dev/null; then
        useradd --uid ${toString cfg.owner.uid} --gid ${toString cfg.owner.uid} \
          --home-dir ${lib.escapeShellArg ownerHome} --no-create-home \
          --shell /bin/bash ${lib.escapeShellArg cfg.owner.name}
      fi
      ${resettableHome}
      install -d -m 0700 -o ${toString cfg.owner.uid} -g ${toString cfg.owner.uid} \
        ${lib.escapeShellArg "${ownerHome}/.config/git"}
      install -d -m 0755 /etc/atlas
      printf '%s\n' ${lib.escapeShellArg layoutId} > /etc/atlas/layout-id
      printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' ${lib.escapeShellArg cfg.owner.name} \
        > /etc/sudoers.d/atlas-owner
      chmod 0440 /etc/sudoers.d/atlas-owner
    ''
  ) cfg.environments;

  incusVolumeDeviceCommands =
    name: environment:
    concatMapStringsSep "\n"
      (
        volumeName:
        let
          mount = environment.volumeMounts.${volumeName};
          source = volumePath cfg.volumes.${volumeName};
          readonly = lib.optionalString (mount.access == "read-only") " readonly=true";
        in
        ''
          incus --force-local config device add ${lib.escapeShellArg "atlas-${name}"} \
            ${lib.escapeShellArg "volume-${volumeName}"} disk \
            source=${lib.escapeShellArg source} path=${lib.escapeShellArg mount.target} \
            shift=true${readonly}
        ''
      )
      (filter (volumeName: hasAttr volumeName cfg.volumes) (builtins.attrNames environment.volumeMounts));

  incusResettableDeviceCommands =
    name: environment:
    lib.optionalString environment.ownerHome (
      concatMapStringsSep "\n" (
        path:
        let
          suffix = lib.replaceStrings [ "." "/" ] [ "" "-" ] path;
          volume = "atlas-${name}-home-${suffix}";
          device = "resettable-${suffix}";
        in
        ''
          incus --force-local storage volume create atlas ${lib.escapeShellArg volume} \
            initial.uid=${toString cfg.owner.uid} initial.gid=${toString cfg.owner.uid} \
            initial.mode=0700 security.shifted=true
          incus --force-local config device add ${lib.escapeShellArg "atlas-${name}"} \
            ${lib.escapeShellArg device} disk pool=atlas \
            source=${lib.escapeShellArg volume} \
            path=${lib.escapeShellArg "${ownerHome}/${path}"} dependent=true
        ''
      ) resettableHomePaths
    );

  incusResettableVolumeCleanupCommands =
    name: environment:
    lib.optionalString environment.ownerHome (
      concatMapStringsSep "\n" (
        path:
        let
          suffix = lib.replaceStrings [ "." "/" ] [ "" "-" ] path;
          volume = "atlas-${name}-home-${suffix}";
        in
        ''
          presence="$(${incusInventory} volume ${lib.escapeShellArg volume})"
          if [ "$presence" = present ]; then
            incus --force-local storage volume delete atlas ${lib.escapeShellArg volume}
          fi
        ''
      ) resettableHomePaths
    );

  incusExpectedDevices =
    name: environment:
    {
      root = {
        type = "disk";
        path = "/";
        pool = "atlas";
      };
      eth0 = {
        type = "nic";
        name = "eth0";
        network = "atlasbr0";
        "ipv4.address" = environmentIpv4ByName.${name};
        "security.acls" = "atlas-private";
      };
      nix-store = {
        type = "disk";
        source = "/nix/store";
        path = "/nix/store";
        readonly = "true";
      };
      atlas-contract = {
        type = "disk";
        source = guestContractRoot;
        path = "/etc/atlas-host";
        readonly = "true";
      };
      atlas-control = {
        type = "proxy";
        bind = "instance";
        listen = "unix:/mnt/atlas-control.sock";
        connect = "unix:/run/atlas/environment-sockets/${name}/control.sock";
        uid = toString cfg.owner.uid;
        gid = toString cfg.owner.uid;
        mode = "0660";
      };
    }
    // lib.optionalAttrs environment.ownerHome {
      owner-home = {
        type = "disk";
        source = ownerHomePath;
        path = ownerHome;
        shift = "true";
      };
    }
    // builtins.listToAttrs (
      map
        (
          volumeName:
          let
            mount = environment.volumeMounts.${volumeName};
          in
          nameValuePair "volume-${volumeName}" (
            {
              type = "disk";
              source = volumePath cfg.volumes.${volumeName};
              path = mount.target;
              shift = "true";
            }
            // lib.optionalAttrs (mount.access == "read-only") { readonly = "true"; }
          )
        )
        (filter (volumeName: hasAttr volumeName cfg.volumes) (builtins.attrNames environment.volumeMounts))
    )
    // builtins.listToAttrs (
      lib.optionals environment.ownerHome (
        map (
          path:
          let
            suffix = lib.replaceStrings [ "." "/" ] [ "" "-" ] path;
          in
          nameValuePair "resettable-${suffix}" {
            type = "disk";
            pool = "atlas";
            source = "atlas-${name}-home-${suffix}";
            path = "${ownerHome}/${path}";
            dependent = "true";
          }
        ) resettableHomePaths
      )
    );

  incusReconcilers = mapAttrs (
    name: environment:
    let
      instance = "atlas-${name}";
      layoutId = environmentLayoutId name environment;
      ownerHomeDevice = lib.optionalString environment.ownerHome ''
        incus --force-local config device add ${lib.escapeShellArg instance} owner-home disk \
          source=${lib.escapeShellArg ownerHomePath} path=${lib.escapeShellArg ownerHome} shift=true
      '';
      ownerHomeVerification = lib.optionalString environment.ownerHome ''
        require_device_value owner-home source ${lib.escapeShellArg ownerHomePath} || return 1
        require_device_value owner-home path ${lib.escapeShellArg ownerHome} || return 1
        require_device_value owner-home shift true || return 1
      '';
      volumeDevices = incusVolumeDeviceCommands name environment;
      resettableDevices = incusResettableDeviceCommands name environment;
      resettableCleanup = incusResettableVolumeCleanupCommands name environment;
      expectedDevicesJson = builtins.toJSON (incusExpectedDevices name environment);
      provisioner = incusGuestProvisioners.${name};
      address = environmentIpv4ByName.${name};
    in
    pkgs.writeShellApplication {
      name = "atlas-incus-reconcile-${name}";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.incus-lts
        pkgs.jq
        pkgs.util-linux
      ];
      text = ''
        set -eu
        instance=${lib.escapeShellArg instance}

        require_config_value() {
          actual="$(
            printf '%s\n' "$instance_record" \
              | jq -r --arg key "$1" '.expanded_config[$key] // ""'
          )"
          if [ "$actual" != "$2" ]; then
            echo "Atlas Incus configuration drifted at $1" >&2
            return 1
          fi
        }

        require_device_value() {
          actual="$(
            printf '%s\n' "$instance_record" \
              | jq -r --arg device "$1" --arg key "$2" \
                '.devices[$device][$key] // ""'
          )"
          if [ "$actual" != "$3" ]; then
            echo "Atlas Incus device $1 drifted at $2" >&2
            return 1
          fi
        }

        quarantine_instance() {
          local failed presence state
          failed=0
          if ! presence="$(${incusInventory} instance "$instance")"; then
            echo "Atlas could not inventory $instance while quarantining it" >&2
            return 1
          fi
          if [ "$presence" = absent ]; then
            return 0
          fi
          if ! incus --force-local config set "$instance" boot.autostart=false; then
            failed=1
          fi
          state=""
          if ! state="$(incus --force-local list ${lib.escapeShellArg "^${instance}$"} --format csv -c s)"; then
            failed=1
          fi
          if [ "$state" != STOPPED ] && ! incus --force-local stop --force "$instance"; then
            failed=1
          fi
          if ! state="$(incus --force-local list ${lib.escapeShellArg "^${instance}$"} --format csv -c s)"; then
            failed=1
            state=""
          fi
          if [ "$state" != STOPPED ]; then
            echo "Atlas could not confirm that $instance was quarantined" >&2
            failed=1
          fi
          return "$failed"
        }

        require_expanded_device_value() {
          actual="$(
            printf '%s\n' "$instance_record" \
              | jq -r --arg device "$1" --arg key "$2" \
                '.expanded_devices[$device][$key] // ""'
          )"
          if [ "$actual" != "$3" ]; then
            echo "Atlas Incus expanded device $1 drifted at $2" >&2
            return 1
          fi
        }

        verify_instance_configuration() {
          expected_devices="$(printf '%s\n' ${lib.escapeShellArg expectedDevicesJson} | jq -cS '.')"
          actual_devices="$(printf '%s\n' "$instance_record" | jq -cS '.devices')"
          if [ "$actual_devices" != "$expected_devices" ]; then
            echo "Atlas Incus managed device inventory drifted" >&2
            return 1
          fi

          profiles="$(printf '%s\n' "$instance_record" | jq -c '.profiles')"
          if [ "$profiles" != '[]' ]; then
            echo "Atlas Incus instance profiles drifted" >&2
            return 1
          fi
          actual_expanded_devices="$(printf '%s\n' "$instance_record" | jq -cS '.expanded_devices')"
          if [ "$actual_expanded_devices" != "$expected_devices" ]; then
            echo "Atlas Incus effective device configuration drifted" >&2
            return 1
          fi

          unexpected_config="$(
            printf '%s\n' "$instance_record" \
              | jq -r '
                  .expanded_config | keys[] |
                  select(
                    startswith("image.") | not
                  ) |
                  select(
                    startswith("volatile.") | not
                  ) |
                  select(. != "boot.autostart") |
                  select(. != "boot.host_shutdown_action") |
                  select(. != "linux.sysctl.net.ipv6.conf.all.disable_ipv6") |
                  select(. != "linux.sysctl.net.ipv6.conf.default.disable_ipv6") |
                  select(. != "security.guestapi") |
                  select(. != "security.idmap.isolated") |
                  select(. != "user.atlas.environment-id") |
                  select(. != "user.atlas.layout-id")
                '
          )"
          if [ -n "$unexpected_config" ]; then
            echo "Atlas Incus effective configuration has unexpected keys: $unexpected_config" >&2
            return 1
          fi

          require_config_value security.idmap.isolated true || return 1
          require_config_value security.guestapi false || return 1
          require_config_value user.atlas.environment-id ${lib.escapeShellArg environment.id} || return 1
          require_config_value linux.sysctl.net.ipv6.conf.all.disable_ipv6 1 || return 1
          require_config_value linux.sysctl.net.ipv6.conf.default.disable_ipv6 1 || return 1
          require_config_value boot.host_shutdown_action force-stop || return 1
          require_config_value boot.autostart false || return 1
          require_expanded_device_value root type disk || return 1
          require_expanded_device_value root path / || return 1
          require_expanded_device_value root pool atlas || return 1
          require_device_value eth0 type nic || return 1
          require_device_value eth0 name eth0 || return 1
          require_device_value eth0 network atlasbr0 || return 1
          require_device_value eth0 ipv4.address ${lib.escapeShellArg address} || return 1
          require_device_value eth0 security.acls atlas-private || return 1
          require_device_value nix-store source /nix/store || return 1
          require_device_value nix-store path /nix/store || return 1
          require_device_value nix-store readonly true || return 1
          require_device_value atlas-contract source ${lib.escapeShellArg guestContractRoot} || return 1
          require_device_value atlas-contract path /etc/atlas-host || return 1
          require_device_value atlas-contract readonly true || return 1
          require_device_value atlas-control bind instance || return 1
          require_device_value atlas-control listen unix:/mnt/atlas-control.sock || return 1
          require_device_value atlas-control connect ${lib.escapeShellArg "unix:/run/atlas/environment-sockets/${name}/control.sock"} || return 1
          require_device_value atlas-control uid ${toString cfg.owner.uid} || return 1
          require_device_value atlas-control gid ${toString cfg.owner.uid} || return 1
          require_device_value atlas-control mode 0660 || return 1
          ${ownerHomeVerification}
        }

        verify_instance() {
          verify_instance_configuration || return 1
          require_config_value user.atlas.layout-id ${lib.escapeShellArg layoutId} || return 1
        }

        mode="''${1:-ensure}"
        case "$mode" in
          ensure|reset)
            if [ "$#" -ne 0 ] && [ "$#" -ne 1 ]; then
              echo "Atlas Incus reconciler received unexpected arguments" >&2
              exit 2
            fi
            ;;
          verify-snapshot)
            if [ "$#" -ne 3 ] || [ "$2" != "$instance" ]; then
              echo "Atlas Incus snapshot verifier received invalid arguments" >&2
              exit 2
            fi
            case "$3" in
              [a-z]|[a-z][a-z0-9-]*) ;;
              *)
                echo "Atlas Incus snapshot verifier received an invalid snapshot" >&2
                exit 2
                ;;
            esac
            if [ "''${#3}" -gt 40 ]; then
              echo "Atlas Incus snapshot verifier received an invalid snapshot" >&2
              exit 2
            fi
            ;;
          *)
            echo "Atlas Incus reconciler accepts ensure, reset, or verify-snapshot" >&2
            exit 2
            ;;
        esac

        lifecycle_lock=${lib.escapeShellArg (environmentLock environment)}
        inherited_lock_fd="''${ATLAS_LIFECYCLE_LOCK_FD:-}"
        if [ -n "$inherited_lock_fd" ]; then
          case "$inherited_lock_fd" in
            *[!0-9]*)
              echo "Atlas received an invalid inherited lifecycle lock" >&2
              exit 1
              ;;
          esac
          inherited_lock_path="$(readlink -f "/proc/self/fd/$inherited_lock_fd" 2>/dev/null || true)"
          if [ "$inherited_lock_path" != "$lifecycle_lock" ]; then
            echo "Atlas received the wrong inherited lifecycle lock" >&2
            exit 1
          fi
          flock --wait 60 "$inherited_lock_fd"
        else
          exec 9>"$lifecycle_lock"
          flock --wait 60 9
        fi

        # Every mutation takes the environment lock before the global Incus
        # reconciliation lock. Snapshot operations need only the first lock.
        exec 8>/run/atlas/locks/incus-reconcile.lock
        flock --wait 60 8
        incus --force-local admin waitready --timeout 60

        if [ "$mode" = verify-snapshot ]; then
          instance_record="$(
            incus --force-local query "/1.0/instances/$instance/snapshots/$3"
          )"
          if ! verify_instance; then
            exit 20
          fi
          exit 0
        fi

        presence="$(${incusInventory} instance "$instance")"
        if [ "$presence" = present ]; then
          actual_layout="$(incus --force-local config get "$instance" user.atlas.layout-id)"
          if [ "$mode" = ensure ] && [ -n "$actual_layout" ] && [ "$actual_layout" != ${lib.escapeShellArg layoutId} ]; then
            quarantine_instance
            echo "Atlas environment ${name} requires an explicit reset for the current instance layout" >&2
            exit 1
          fi
          if [ "$mode" = ensure ] && [ "$actual_layout" = ${lib.escapeShellArg layoutId} ]; then
            instance_record="$(incus --force-local query "/1.0/instances/$instance")"
            if ! verify_instance; then
              quarantine_instance
              echo "Atlas environment ${name} requires an explicit reset after instance drift" >&2
              exit 1
            fi
            if [ "$(incus --force-local list ${lib.escapeShellArg "^${instance}$"} --format csv -c s)" != RUNNING ]; then
              incus --force-local start "$instance"
            fi
            instance_record="$(incus --force-local query "/1.0/instances/$instance")"
            if ! verify_instance; then
              quarantine_instance
              echo "Atlas environment ${name} requires an explicit reset after instance drift" >&2
              exit 1
            fi
            exit 0
          fi
          snapshots="$(incus --force-local snapshot list "$instance" --format csv -c n)"
          if [ -n "$snapshots" ]; then
            if [ "$mode" = ensure ]; then
              quarantine_instance
            fi
            echo "Atlas refuses to recreate ${name} while named snapshots exist; delete them explicitly before reset" >&2
            exit 1
          fi
          incus --force-local delete --force "$instance"
        fi

        # A failed create can leave an unattached resettable volume behind.
        # Those volumes never contain durable owner data and are safe to clear
        # before reconstructing an incomplete instance.
        ${resettableCleanup}

        creation_pending=true
        cleanup_incomplete_creation() {
          local status="$?"
          trap - EXIT
          if [ "$creation_pending" = true ] && ! quarantine_instance; then
            status=1
          fi
          exit "$status"
        }
        trap cleanup_incomplete_creation EXIT
        incus --force-local init ${lib.escapeShellArg incusImageAlias} "$instance" \
          --no-profiles --storage atlas \
          --config security.idmap.isolated=true \
          --config security.guestapi=false \
          --config user.atlas.environment-id=${lib.escapeShellArg environment.id} \
          --config linux.sysctl.net.ipv6.conf.all.disable_ipv6=1 \
          --config linux.sysctl.net.ipv6.conf.default.disable_ipv6=1 \
          --config boot.autostart=false \
          --config boot.host_shutdown_action=force-stop
        incus --force-local config device add "$instance" eth0 nic \
          name=eth0 network=atlasbr0 ipv4.address=${lib.escapeShellArg address} \
          security.acls=atlas-private
        incus --force-local config device add "$instance" nix-store disk \
          source=/nix/store path=/nix/store readonly=true
        incus --force-local config device add "$instance" atlas-contract disk \
          source=${lib.escapeShellArg guestContractRoot} \
          path=/etc/atlas-host readonly=true
        incus --force-local config device add "$instance" atlas-control proxy \
          bind=instance listen=unix:/mnt/atlas-control.sock \
          connect=unix:${lib.escapeShellArg "/run/atlas/environment-sockets/${name}/control.sock"} \
          uid=${toString cfg.owner.uid} gid=${toString cfg.owner.uid} mode=0660
        ${ownerHomeDevice}
        ${volumeDevices}
        ${resettableDevices}
        incus --force-local start "$instance"
        timeout -k 5 60 incus --force-local exec "$instance" -T -n -- true
        incus --force-local exec "$instance" -T -n -- \
          /bin/bash ${provisioner}
        instance_record="$(incus --force-local query "/1.0/instances/$instance")"
        verify_instance_configuration
        incus --force-local config set "$instance" user.atlas.layout-id=${lib.escapeShellArg layoutId}
        instance_record="$(incus --force-local query "/1.0/instances/$instance")"
        verify_instance
        creation_pending=false
        trap - EXIT
      '';
    }
  ) cfg.environments;

  incusResetCommands = mapAttrs (
    name: _environment:
    pkgs.writeShellApplication {
      name = "atlas-incus-reset-${name}";
      text = ''
        exec ${incusReconcilers.${name}}/bin/atlas-incus-reconcile-${name} reset
      '';
    }
  ) cfg.environments;

  incusVerifyCommands = mapAttrs (
    name: _environment:
    pkgs.writeShellApplication {
      name = "atlas-incus-verify-${name}";
      text = ''
        if [ "$#" -ne 2 ]; then
          echo "Atlas Incus snapshot verifier requires an instance and snapshot" >&2
          exit 2
        fi
        exec ${incusReconcilers.${name}}/bin/atlas-incus-reconcile-${name} \
          verify-snapshot "$1" "$2"
      '';
    }
  ) cfg.environments;

  incusEntryLaunchers = mapAttrs (
    name: environment:
    let
      environmentShell = environmentShells.${name};
      environmentAssignments = environmentAssignmentLines name environment;
      instance = "atlas-${name}";
    in
    pkgs.writeShellApplication {
      name = "atlas-enter-${name}";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.incus-lts
        pkgs.util-linux
      ];
      text = ''
        if [ "$#" -eq 1 ] && [ "$1" = interactive ]; then
          incus_flags=()
          command=(${environmentShell} -i)
        elif [ "$#" -eq 2 ] && [ "$1" = command ]; then
          incus_flags=(-T)
          command=(${environmentShell} -c "$2")
        else
          echo "Atlas entry launcher rejected unsupported arguments" >&2
          exit 2
        fi

        ${incusReconcilers.${name}}/bin/atlas-incus-reconcile-${name} ensure

        exec incus --force-local exec ${lib.escapeShellArg instance} "''${incus_flags[@]}" \
          --user=${toString cfg.owner.uid} --group=${toString cfg.owner.uid} \
          --cwd=${lib.escapeShellArg ownerHome} -- \
          ${pkgs.coreutils}/bin/env -i \
        ${environmentAssignments} \
          "''${command[@]}"
      '';
    }
  ) cfg.environments;

  entryLaunchers = incusEntryLaunchers;

  entryShells = mapAttrs (
    name: _environment:
    let
      launcher = entryLaunchers.${name};
      shell = pkgs.writeShellApplication {
        name = "atlas-shell-${name}";
        text = ''
          if [ "$#" -eq 0 ]; then
            exec /run/wrappers/bin/sudo -n ${launcher}/bin/atlas-enter-${name} interactive
          fi

          if [ "$#" -eq 2 ] && [ "$1" = "-c" ]; then
            exec /run/wrappers/bin/sudo -n ${launcher}/bin/atlas-enter-${name} command "$2"
          fi

          echo "Atlas entry accepts an interactive login or one remote command" >&2
          exit 2
        '';
      };
    in
    shell.overrideAttrs (old: {
      passthru = (old.passthru or { }) // {
        shellPath = "/bin/atlas-shell-${name}";
      };
    })
  ) cfg.environments;

  referencedLayers = concatMap (name: cfg.environments.${name}.layers) environmentNames;
  referencedVolumes = concatMap (
    name: builtins.attrNames cfg.environments.${name}.volumeMounts
  ) environmentNames;
  unknownLayers = unique (filter (layer: !(hasAttr layer cfg.environmentLayers)) referencedLayers);
  unknownVolumes = unique (filter (volume: !(hasAttr volume cfg.volumes)) referencedVolumes);
  duplicateLayerEnvironments = filter (
    name:
    let
      layers = cfg.environments.${name}.layers;
    in
    length layers != length (unique layers)
  ) environmentNames;
  duplicateMountTargetEnvironments = filter (
    name:
    let
      targets = mapAttrsToList (_volume: mount: mount.target) cfg.environments.${name}.volumeMounts;
    in
    length targets != length (unique targets)
  ) environmentNames;
  pathsOverlap =
    left: right: left == right || hasPrefix "${left}/" right || hasPrefix "${right}/" left;
  overlappingMountTargetEnvironments = filter (
    name:
    let
      targets = mapAttrsToList (_volume: mount: mount.target) cfg.environments.${name}.volumeMounts;
    in
    builtins.any (left: builtins.any (right: left != right && pathsOverlap left right) targets) targets
  ) environmentNames;
  environmentIds = map (name: cfg.environments.${name}.id) environmentNames;
  environmentUids = map (name: cfg.environments.${name}.uid) environmentNames;
  volumeIds = [ cfg.owner.homeVolumeId ] ++ map (name: cfg.volumes.${name}.id) volumeNames;
  allVariableNames = unique (
    concatMap (name: builtins.attrNames cfg.environmentLayers.${name}.variables) layerNames
    ++ concatMap (name: builtins.attrNames cfg.environments.${name}.variables) environmentNames
  );
  invalidVariableNames = filter (
    name: builtins.match "^[A-Za-z_][A-Za-z0-9_]*$" name == null
  ) allVariableNames;
  runtimeVariableNames = [
    "GIT_CONFIG_GLOBAL"
    "GIT_CONFIG_SYSTEM"
    "HOME"
    "LOGNAME"
    "PATH"
    "SHELL"
    "USER"
  ];
  reservedVariableNames = filter (
    name: hasPrefix "ATLAS_" name || builtins.elem name runtimeVariableNames
  ) allVariableNames;
  invalidEnvironmentNames = filter (
    name: builtins.match "^[a-z][a-z0-9-]{0,19}$" name == null
  ) environmentNames;
  ownerNameValid = builtins.match "^[a-z_][a-z0-9_-]{0,31}$" cfg.owner.name != null;
  reservedOwnerNames = [
    "root"
    "daemon"
    "bin"
    "sys"
    "sync"
    "games"
    "man"
    "lp"
    "mail"
    "news"
    "uucp"
    "proxy"
    "www-data"
    "backup"
    "list"
    "irc"
    "_apt"
    "nobody"
  ];
  invalidVolumeNames = filter (
    name: builtins.match "^[a-z][a-z0-9-]{0,39}$" name == null
  ) volumeNames;
  validUuid =
    id:
    builtins.match "^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$" id
    != null;
  invalidEnvironmentIds = filter (id: !(validUuid id)) environmentIds;
  invalidVolumeIds = filter (id: !(validUuid id)) volumeIds;
  allMountTargets = concatMap (
    name: mapAttrsToList (_volume: mount: mount.target) cfg.environments.${name}.volumeMounts
  ) environmentNames;
  ownerHomeChildMountTargets = unique (
    filter (path: hasPrefix "${ownerHome}/" path) (
      concatMap (
        name:
        lib.optionals cfg.environments.${name}.ownerHome (
          mapAttrsToList (_volume: mount: mount.target) cfg.environments.${name}.volumeMounts
        )
      ) environmentNames
    )
  );
  ownerHomeManagedDirectories = unique (
    [ ".local" ]
    ++ resettableHomePaths
    ++ map (path: lib.removePrefix "${ownerHome}/" path) ownerHomeChildMountTargets
  );
  ownerHomePrepareProgram = pkgs.writeText "atlas-owner-home-prepare.py" ''
    import os
    import stat
    import sys

    owner_home = sys.argv[1]
    owner_uid = int(sys.argv[2])
    managed_paths = sys.argv[3:]
    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC

    try:
        owner_fd = os.open(owner_home, directory_flags)
    except OSError as error:
        raise SystemExit(f"Atlas refused an invalid durable owner home: {error}")

    try:
        owner_metadata = os.fstat(owner_fd)
        if not stat.S_ISDIR(owner_metadata.st_mode):
            raise SystemExit("Atlas durable owner home is not a directory")

        for relative_path in managed_paths:
            current_fd = os.dup(owner_fd)
            try:
                for component in relative_path.split("/"):
                    if component in {"", ".", ".."}:
                        raise SystemExit("Atlas refused an invalid managed owner-home path")
                    try:
                        os.mkdir(component, mode=0o700, dir_fd=current_fd)
                    except FileExistsError:
                        pass
                    try:
                        child_fd = os.open(component, directory_flags, dir_fd=current_fd)
                    except OSError as error:
                        raise SystemExit(
                            "Atlas refused a symbolic link or non-directory below "
                            f"the durable owner home: {relative_path}: {error}"
                        )
                    os.close(current_fd)
                    current_fd = child_fd
                    os.fchown(current_fd, owner_uid, owner_uid)
                    os.fchmod(current_fd, 0o700)
            finally:
                os.close(current_fd)
    finally:
        os.close(owner_fd)
  '';
  isSafeMountTarget =
    path:
    let
      components = builtins.tail (lib.splitString "/" path);
    in
    hasPrefix "/" path
    && path != "/"
    && builtins.match "^/[-A-Za-z0-9._+/]+$" path != null
    && lib.all (component: component != "" && component != "." && component != "..") components;
  invalidMountTargets = unique (filter (path: !(isSafeMountTarget path)) allMountTargets);
  reservedMountTrees = [
    "/dev"
    "/etc/atlas"
    "/etc/atlas-host"
    "/mnt/atlas-control.sock"
    "/nix/store"
    "/proc"
    "/run/atlas"
    "/sys"
  ];
  invalidReservedMountTargets = unique (
    filter (
      path: builtins.any (reserved: pathsOverlap path reserved) reservedMountTrees
    ) allMountTargets
  );
  invalidHomeMountTargets = unique (
    filter (
      path:
      path == ownerHome
      || hasPrefix "${path}/" ownerHome
      || builtins.any (
        resettablePath: pathsOverlap path "${ownerHome}/${resettablePath}"
      ) resettableHomePaths
    ) allMountTargets
  );
in
{
  options.atlas.host = {
    storage.adapter = mkOption {
      default = "host-directory";
      type = types.enum [
        "host-directory"
        "btrfs-subvolume"
      ];
      description = ''
        Host storage mechanism for resettable environment roots and durable
        volumes. The Btrfs adapter requires /var/lib/atlas to reside on Btrfs.
      '';
    };

    storage.atRestEncryption = mkOption {
      default = "none";
      type = types.enum [
        "none"
        "luks2-operator-passphrase"
        "provider-managed-volume"
      ];
      description = ''
        Deployment fact describing encryption for persistent Atlas state. This
        reports a configured mechanism; runtime tests must establish evidence.
      '';
    };

    storage.hostRecoveryReserve = mkOption {
      default = false;
      type = types.bool;
      description = ''
        Whether the deployment places Atlas data on a capacity boundary that
        cannot consume the host filesystem's recovery space.
      '';
    };

    owner = {
      name = mkOption {
        type = types.str;
        description = "Conventional Linux username for the single human owner inside environments.";
      };
      uid = mkOption {
        type = types.ints.between 1000 19999;
        description = "Stable Linux UID for the human owner inside environment user namespaces.";
      };
      homeVolumeId = mkOption {
        type = types.str;
        description = "Opaque UUID for the automatically managed durable owner-home volume.";
      };
    };

    environmentLayers = mkOption {
      default = { };
      type = types.attrsOf (
        types.submodule {
          options = {
            variables = mkOption {
              default = { };
              type = types.attrsOf types.str;
              description = "Reusable non-secret variables for this configuration layer.";
            };
            packages = mkOption {
              default = { };
              type = types.attrsOf types.package;
              description = "Aliased non-secret tool packages for this configuration layer.";
            };
            git.config = mkOption {
              default = { };
              type = gitIni.type;
              description = "Managed non-secret Git configuration for this configuration layer.";
            };
          };
        }
      );
      description = "Reusable non-secret configuration layers for Atlas environments.";
    };

    volumes = mkOption {
      default = { };
      type = types.attrsOf (
        types.submodule {
          options = {
            id = mkOption {
              type = types.str;
              description = "Opaque, non-reusable volume UUID.";
            };
          };
        }
      );
      description = "Durable Atlas volumes that environments may mount explicitly.";
    };

    environments = mkOption {
      default = { };
      type = types.attrsOf (
        types.submodule {
          options = {
            id = mkOption {
              type = types.str;
              description = "Opaque, non-reusable environment UUID.";
            };
            uid = mkOption {
              type = types.ints.between 20000 59999;
              description = "Stable host login UID for the declarative entry adapter.";
            };
            layers = mkOption {
              default = [ ];
              type = types.listOf types.str;
              description = "Ordered reusable configuration layers.";
            };
            variables = mkOption {
              default = { };
              type = types.attrsOf types.str;
              description = "Non-secret instance variables applied after all layers.";
            };
            packages = mkOption {
              default = { };
              type = types.attrsOf types.package;
              description = "Aliased non-secret tool packages applied after all layers.";
            };
            git.config = mkOption {
              default = { };
              type = gitIni.type;
              description = "Managed non-secret Git configuration applied after all layers.";
            };
            volumeMounts = mkOption {
              default = { };
              type = types.attrsOf (
                types.submodule {
                  options = {
                    target = mkOption {
                      type = types.str;
                      description = "Absolute mount point inside the environment.";
                    };
                    access = mkOption {
                      default = "read-write";
                      type = types.enum [
                        "read-only"
                        "read-write"
                      ];
                    };
                  };
                }
              );
              description = "Explicit durable-volume attachments for this resettable environment.";
            };
            ownerHome = mkOption {
              default = false;
              type = types.bool;
              description = ''
                Compose the automatically managed durable owner home into this
                environment, with the v0 resettable configuration paths mounted
                from the environment root.
              '';
            };
          };
        }
      );
      description = "Named persistent, resettable Atlas environment instances.";
    };

    environmentContract = mkOption {
      readOnly = true;
      type = types.attrs;
      description = "Machine-readable Environment Entry v0 adapter facts.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = invalidEnvironmentNames == [ ];
        message = "Atlas environment names must be lowercase slugs of at most 20 characters: ${builtins.toJSON invalidEnvironmentNames}";
      }
      {
        assertion = ownerNameValid && !(builtins.elem cfg.owner.name reservedOwnerNames);
        message = "Atlas owner name must be a non-system conventional lowercase Linux username";
      }
      {
        assertion = invalidVolumeNames == [ ];
        message = "Atlas volume names must be lowercase slugs of at most 40 characters: ${builtins.toJSON invalidVolumeNames}";
      }
      {
        assertion = invalidEnvironmentIds == [ ];
        message = "Atlas environment IDs must be lowercase RFC 4122 UUIDs: ${builtins.toJSON invalidEnvironmentIds}";
      }
      {
        assertion = invalidVolumeIds == [ ];
        message = "Atlas volume IDs must be lowercase RFC 4122 UUIDs: ${builtins.toJSON invalidVolumeIds}";
      }
      {
        assertion = length environmentIds == length (unique environmentIds);
        message = "Atlas environment IDs must be unique";
      }
      {
        assertion = length environmentNames <= 254 * 254;
        message = "Atlas private IPv4 address capacity is exhausted (64516 environments)";
      }
      {
        assertion = length environmentNames == length (unique (builtins.attrValues environmentIpv4ByName));
        message = "Atlas environment IPv4 collision: choose a different UUID for the new environment; existing addresses are never reassigned";
      }
      {
        assertion = length environmentUids == length (unique environmentUids);
        message = "Atlas environment UIDs must be unique";
      }
      {
        assertion = length volumeIds == length (unique volumeIds);
        message = "Atlas owner home volume ID and declared volume IDs must be unique";
      }
      {
        assertion = unknownLayers == [ ];
        message = "Atlas environment definitions reference unknown layers: ${builtins.toJSON unknownLayers}";
      }
      {
        assertion = unknownVolumes == [ ];
        message = "Atlas environment definitions reference unknown volumes: ${builtins.toJSON unknownVolumes}";
      }
      {
        assertion = duplicateLayerEnvironments == [ ];
        message = "Atlas environments cannot repeat a configuration layer: ${builtins.toJSON duplicateLayerEnvironments}";
      }
      {
        assertion = duplicateMountTargetEnvironments == [ ];
        message = "Atlas environments cannot mount two volumes at the same target: ${builtins.toJSON duplicateMountTargetEnvironments}";
      }
      {
        assertion = overlappingMountTargetEnvironments == [ ];
        message = "Atlas environments cannot use overlapping volume mount targets: ${builtins.toJSON overlappingMountTargetEnvironments}";
      }
      {
        assertion = invalidMountTargets == [ ];
        message = "Atlas volume mount targets must be canonical absolute paths: ${builtins.toJSON invalidMountTargets}";
      }
      {
        assertion = invalidReservedMountTargets == [ ] && invalidHomeMountTargets == [ ];
        message = "Atlas volume mount targets cannot shadow runtime-managed paths: ${
          builtins.toJSON (unique (invalidReservedMountTargets ++ invalidHomeMountTargets))
        }";
      }
      {
        assertion = invalidVariableNames == [ ];
        message = "Atlas environment variable names are invalid: ${builtins.toJSON invalidVariableNames}";
      }
      {
        assertion = reservedVariableNames == [ ];
        message = "Atlas environment definitions cannot set reserved ATLAS_ or runtime variables: ${builtins.toJSON reservedVariableNames}";
      }
    ];

    atlas.host.environmentContract = {
      version = 7;
      adapter = doctor.adapter;
      baseImage = baseImageRecord;
      composition = doctor.composition;
      identity = doctor.identity;
      owner = ownerRecord;
      volumes = volumeRecords;
      environments = environmentRecords;
    };

    environment = {
      etc."atlas/control-contract.json".source = controlContractFile;
      shells = builtins.attrValues entryShells;
      systemPackages = [
        atlasControl
      ]
      ++ lib.optionals btrfsStorage [ pkgs.btrfs-progs ]
      ++ [ pkgs.incus-lts ];
    };

    security.apparmor.enable = true;

    networking = {
      nftables.enable = true;
      firewall.trustedInterfaces = [ "atlasbr0" ];
      nftables.tables.atlas-host-input = {
        family = "inet";
        content = ''
          chain input {
            type filter hook input priority 10; policy accept;
            iifname "atlasbr0" tcp dport 53 accept
            iifname "atlasbr0" udp dport { 53, 67 } accept
            iifname "atlasbr0" fib daddr type { local, broadcast, multicast } drop
          }
        '';
      };
      dhcpcd.denyInterfaces = [
        "atlasbr0"
        "veth*"
      ];
    };

    virtualisation.incus = {
      enable = true;
      package = pkgs.incus-lts;
      preseed = {
        storage_pools = [
          {
            name = "atlas";
            driver = if btrfsStorage then "btrfs" else "dir";
            config.source = "${toString cfg.dataRoot}/incus-pool";
          }
        ];
        networks = [
          {
            name = "atlasbr0";
            type = "bridge";
            config = {
              "ipv4.address" = "10.211.0.1/16";
              "ipv4.nat" = "true";
              "ipv6.address" = "none";
            };
          }
        ];
        profiles = [
          {
            name = "default";
            description = "Atlas environment profile";
            devices = {
              root = {
                type = "disk";
                path = "/";
                pool = "atlas";
              };
              eth0 = {
                type = "nic";
                name = "eth0";
                network = "atlasbr0";
              };
            };
          }
        ];
      };
    };

    security.sudo = {
      # Each fixed login can execute only its exact environment launcher. PTY
      # mediation breaks long noninteractive commands across the namespace
      # transition without adding a useful privilege boundary here.
      extraConfig = concatMapStringsSep "\n" (
        name: "Defaults:${loginUser name} !use_pty"
      ) environmentNames;
      extraRules = mapAttrsToList (name: _environment: {
        users = [ (loginUser name) ];
        commands = [
          {
            command = "${entryLaunchers.${name}}/bin/atlas-enter-${name}";
            options = [ "NOPASSWD" ];
          }
        ];
      }) cfg.environments;
    };

    systemd = {
      services = {
        # Incus and its preseed must never initialize the pool on the host
        # filesystem beneath a late (for example nofail provider) data mount.
        incus.unitConfig.RequiresMountsFor = [ (toString cfg.dataRoot) ];

        atlas-storage-prepare = mkIf btrfsStorage {
          description = "Prepare Atlas Btrfs storage";
          requiredBy = [ "atlas-host.target" ];
          before = [
            "atlas-host-contract.service"
            "atlas-host.target"
          ];
          after = [
            "local-fs.target"
            "systemd-tmpfiles-setup.service"
          ];
          unitConfig.RequiresMountsFor = [ (toString cfg.dataRoot) ];
          path = [
            pkgs.btrfs-progs
            pkgs.coreutils
            pkgs.systemd
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            set -eu
            if [ "$(stat -f -c %T ${lib.escapeShellArg (toString cfg.dataRoot)})" != btrfs ]; then
              echo "Atlas Btrfs adapter requires ${toString cfg.dataRoot} to reside on Btrfs" >&2
              exit 1
            fi

            # A provider-backed dataRoot can mount after the global tmpfiles
            # pass. Replay only Atlas's managed subtree on the mounted
            # filesystem before creating Btrfs subvolumes beneath it.
            systemd-tmpfiles --create --prefix=${lib.escapeShellArg (toString cfg.dataRoot)}

            if [ -L ${lib.escapeShellArg ownerHomePath} ]; then
              echo "Atlas refused a symbolic link at the durable owner home" >&2
              exit 1
            fi
            if [ -e ${lib.escapeShellArg ownerHomePath} ]; then
              if ! btrfs subvolume show ${lib.escapeShellArg ownerHomePath} >/dev/null 2>&1; then
                echo "Atlas durable owner home is not a Btrfs subvolume" >&2
                exit 1
              fi
            else
              btrfs subvolume create ${lib.escapeShellArg ownerHomePath} >/dev/null
            fi
            chmod 0700 ${lib.escapeShellArg ownerHomePath}
            chown ${toString cfg.owner.uid}:${toString cfg.owner.uid} ${lib.escapeShellArg ownerHomePath}
            ${concatMapStringsSep "\n" (
              name:
              let
                path = volumePath cfg.volumes.${name};
              in
              ''
                if [ -L ${lib.escapeShellArg path} ]; then
                  echo "Atlas refused a symbolic link at durable volume ${name}" >&2
                  exit 1
                fi
                if [ -e ${lib.escapeShellArg path} ]; then
                  if ! btrfs subvolume show ${lib.escapeShellArg path} >/dev/null 2>&1; then
                    echo "Atlas durable volume ${name} is not a Btrfs subvolume" >&2
                    exit 1
                  fi
                else
                  btrfs subvolume create ${lib.escapeShellArg path} >/dev/null
                fi
                chmod 0700 ${lib.escapeShellArg path}
                chown ${toString cfg.owner.uid}:${toString cfg.owner.uid} ${lib.escapeShellArg path}
              ''
            ) volumeNames}
          '';
        };

        atlas-owner-home-prepare = {
          description = "Safely prepare Atlas owner-home mountpoints";
          requires = lib.optional btrfsStorage "atlas-storage-prepare.service";
          after = [
            "systemd-tmpfiles-setup.service"
          ]
          ++ lib.optional btrfsStorage "atlas-storage-prepare.service";
          unitConfig.RequiresMountsFor = [ ownerHomePath ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            exec ${pkgs.python3}/bin/python3 -P \
              ${ownerHomePrepareProgram} \
              ${lib.escapeShellArg ownerHomePath} \
              ${toString cfg.owner.uid} \
              ${concatMapStringsSep " " lib.escapeShellArg ownerHomeManagedDirectories}
          '';
        };

        atlas-guest-contract = {
          description = "Publish the guest-visible Atlas control contract";
          requiredBy = [ "atlas-host.target" ];
          before = [ "atlas-host.target" ];
          after = [ "systemd-tmpfiles-setup.service" ];
          restartTriggers = [ controlContractFile ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [ pkgs.coreutils ];
          script = ''
            set -eu
            next="$(mktemp ${guestContractRoot}/.control-contract.json.XXXXXX)"
            trap 'rm -f "$next"' EXIT
            install -m 0644 ${controlContractFile} "$next"
            mv -f "$next" ${guestContractRoot}/control-contract.json
            trap - EXIT
          '';
        };

        atlas-incus-image = {
          description = "Import the pinned Atlas Ubuntu image into Incus";
          requiredBy = [ "atlas-host.target" ];
          before = [
            "atlas-incus-network-policy.service"
            "atlas-host.target"
          ];
          requires = [ "incus-preseed.service" ];
          after = [ "incus-preseed.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [
            pkgs.coreutils
            pkgs.incus-lts
            pkgs.jq
          ];
          script = ''
            set -euo pipefail
            incus --force-local admin waitready --timeout 60
            expected_fingerprint="$(
              cat ${incusImageMetadata} ${incusImageRoot} | sha256sum
            )"
            expected_fingerprint="''${expected_fingerprint%% *}"
            images="$(incus --force-local image list --format json)"
            matching_images="$(
              printf '%s\n' "$images" | jq -c \
                --arg alias ${lib.escapeShellArg incusImageAlias} \
                '[.[] | select(any(.aliases[]?; .name == $alias))]'
            )"
            image_count="$(printf '%s\n' "$matching_images" | jq -r 'length')"
            if [ "$image_count" = 0 ]; then
              incus --force-local image import ${incusImageMetadata} ${incusImageRoot} \
                --alias ${lib.escapeShellArg incusImageAlias}
              images="$(incus --force-local image list --format json)"
              matching_images="$(
                printf '%s\n' "$images" | jq -c \
                  --arg alias ${lib.escapeShellArg incusImageAlias} \
                  '[.[] | select(any(.aliases[]?; .name == $alias))]'
              )"
              image_count="$(printf '%s\n' "$matching_images" | jq -r 'length')"
            fi
            if [ "$image_count" != 1 ]; then
              echo "Atlas image alias did not resolve to exactly one image" >&2
              exit 1
            fi
            fingerprint="$(printf '%s\n' "$matching_images" | jq -r '.[0].fingerprint')"
            if [ "$fingerprint" != "$expected_fingerprint" ]; then
              echo "Atlas image alias does not resolve to the declared image bytes" >&2
              exit 1
            fi
            incus --force-local image set-property ${lib.escapeShellArg incusImageAlias} \
              user.atlas.content-id=${lib.escapeShellArg incusImageContentId}
            images="$(incus --force-local image list --format json)"
            matching_images="$(
              printf '%s\n' "$images" | jq -c \
                --arg alias ${lib.escapeShellArg incusImageAlias} \
                '[.[] | select(any(.aliases[]?; .name == $alias))]'
            )"
            content_id="$(
              printf '%s\n' "$matching_images" \
                | jq -r '.[0].properties["user.atlas.content-id"] // ""'
            )"
            if [ "$content_id" != ${lib.escapeShellArg incusImageContentId} ]; then
              echo "Atlas image alias does not match the declared image content" >&2
              exit 1
            fi
          '';
        };

        atlas-incus-inventory = {
          description = "Quarantine undeclared Atlas Incus environments";
          requiredBy = [ "atlas-host.target" ];
          before = [
            "atlas-host.target"
          ]
          ++ builtins.map (name: "${environmentServiceName name}.service") environmentNames;
          requires = [ "incus-preseed.service" ];
          after = [ "incus-preseed.service" ];
          restartTriggers = [ incusDeclaredInstances ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.incus-lts
            pkgs.util-linux
          ];
          script = ''
            set -eu
            incus --force-local admin waitready --timeout 60
            instances="$(${incusInventory} instance)"
            while IFS= read -r instance; do
              [ -n "$instance" ] || continue
              if grep -Fqx -- "$instance" ${incusDeclaredInstances}; then
                continue
              fi

              environment_id="$(incus --force-local config get "$instance" user.atlas.environment-id)"
              if ! printf '%s\n' "$environment_id" | grep -Eq \
                '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
                echo "Atlas-marked instance $instance has no valid environment identity" >&2
                exit 1
              fi
              exec 9>"/run/atlas/locks/$environment_id.lock"
              flock --wait 60 9

              exec 8>/run/atlas/locks/incus-reconcile.lock
              flock --wait 60 8
              presence="$(${incusInventory} instance "$instance")"
              if [ "$presence" != present ]; then
                echo "Atlas-marked instance $instance disappeared during inventory" >&2
                exit 1
              fi
              current_environment_id="$(
                incus --force-local config get "$instance" user.atlas.environment-id
              )"
              if [ "$current_environment_id" != "$environment_id" ]; then
                echo "Atlas-marked instance $instance changed identity during inventory" >&2
                exit 1
              fi
              incus --force-local config set "$instance" boot.autostart=false
              state="$(incus --force-local list "^$instance$" --format csv -c s)"
              if [ "$state" != STOPPED ]; then
                incus --force-local stop --force "$instance"
                state="$(incus --force-local list "^$instance$" --format csv -c s)"
              fi
              if [ "$state" != STOPPED ]; then
                echo "Atlas-marked instance $instance did not stop during inventory" >&2
                exit 1
              fi
              flock -u 8
              flock -u 9
            done <<< "$instances"
          '';
        };

        atlas-incus-network-policy = {
          description = "Apply the Atlas private environment network policy";
          requiredBy = [ "atlas-host.target" ];
          before = [ "atlas-host.target" ];
          requires = [ "atlas-incus-image.service" ];
          after = [ "atlas-incus-image.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [ pkgs.incus-lts ];
          script = ''
            set -eu
            presence="$(${incusInventory} acl atlas-private)"
            if [ "$presence" = present ]; then
              incus --force-local network acl edit atlas-private < ${incusPrivateAclFile}
            else
              incus --force-local network acl create atlas-private < ${incusPrivateAclFile}
            fi
          '';
        };

        atlas-host-contract = mkIf btrfsStorage {
          requires = [
            "atlas-storage-prepare.service"
            "atlas-owner-home-prepare.service"
          ];
          after = [ "atlas-owner-home-prepare.service" ];
        };

        atlas-control = {
          description = "Atlas public peer-authenticated inspection service";
          after = [ "atlas-host-contract.service" ];
          serviceConfig = {
            ExecStart = "${atlasControl}/bin/atlas serve";
            User = "root";
            Group = "root";
            Slice = "atlas-control.slice";
            LockPersonality = true;
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectControlGroups = true;
            ProtectHome = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectSystem = "strict";
            Restart = "on-failure";
            RestrictAddressFamilies = [ "AF_UNIX" ];
            RestrictSUIDSGID = true;
          };
        };

        atlas-manage = {
          description = "Atlas root-only lifecycle management service";
          after = [ "atlas-host-contract.service" ];
          serviceConfig = {
            ExecStart = "${atlasControl}/bin/atlas serve --management --incus ${pkgs.incus-lts}/bin/incus${lib.optionalString btrfsStorage " --btrfs ${pkgs.btrfs-progs}/bin/btrfs"}";
            User = "root";
            Group = "root";
            Slice = "atlas-control.slice";
            AmbientCapabilities = [ ];
            # Traverse owner-only data paths and query Btrfs subvolume UUIDs.
            CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ] ++ lib.optional btrfsStorage "CAP_SYS_ADMIN";
            LockPersonality = true;
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectControlGroups = true;
            ProtectHome = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectSystem = "strict";
            ReadWritePaths = [ "/run/atlas/locks" ];
            Restart = "on-failure";
            RestrictAddressFamilies = [ "AF_UNIX" ];
            RestrictSUIDSGID = true;
          };
        };
      }
      // mapAttrs' (
        name: _environment:
        nameValuePair (environmentServiceName name) {
          description = "Persistent Atlas Incus environment ${name}";
          requiredBy = [ "atlas-host.target" ];
          before = [ "atlas-host.target" ];
          requires = [
            "atlas-control.socket"
            "atlas-guest-contract.service"
            "atlas-incus-network-policy.service"
            "atlas-incus-inventory.service"
            "atlas-owner-home-prepare.service"
            "${environmentControlServiceName name}.socket"
          ];
          after = [
            "atlas-control.socket"
            "atlas-guest-contract.service"
            "atlas-incus-network-policy.service"
            "atlas-incus-inventory.service"
            "atlas-owner-home-prepare.service"
            "${environmentControlServiceName name}.socket"
          ];
          restartTriggers = [ environmentConfigFiles.${name} ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${incusReconcilers.${name}}/bin/atlas-incus-reconcile-${name} ensure";
            TimeoutStartSec = "10min";
          };
        }
      ) cfg.environments
      // mapAttrs' (
        name: _environment:
        nameValuePair (environmentControlServiceName name) {
          description = "Atlas environment-bound control listener for ${name}";
          serviceConfig = {
            ExecStart = "${atlasControl}/bin/atlas serve --environment ${name}";
            User = "root";
            Group = "root";
            Slice = "atlas-control.slice";
            LockPersonality = true;
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectControlGroups = true;
            ProtectHome = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectSystem = "strict";
            RestrictAddressFamilies = [ "AF_UNIX" ];
            RestrictSUIDSGID = true;
          };
        }
      ) cfg.environments;

      sockets = {
        atlas-control = {
          description = "Atlas public local control socket";
          wantedBy = [ "atlas-host.target" ];
          before = [ "atlas-host.target" ];
          socketConfig = {
            ListenStream = "/run/atlas/public/control.sock";
            SocketMode = "0666";
            DirectoryMode = "0755";
            RemoveOnStop = true;
          };
        };

        atlas-manage = {
          description = "Atlas root-only lifecycle socket";
          wantedBy = [ "atlas-host.target" ];
          before = [ "atlas-host.target" ];
          socketConfig = {
            ListenStream = "/run/atlas/manage.sock";
            SocketMode = "0600";
            DirectoryMode = "0755";
            RemoveOnStop = true;
          };
        };
      }
      // mapAttrs' (
        name: _environment:
        nameValuePair (environmentControlServiceName name) {
          description = "Atlas environment-bound control socket for ${name}";
          socketConfig = {
            ListenStream = "/run/atlas/environment-sockets/${name}/control.sock";
            SocketMode = "0600";
            DirectoryMode = "0700";
            RemoveOnStop = true;
          };
        }
      ) cfg.environments;

      tmpfiles.rules = [
        "d /run/atlas 0755 root root - -"
        "d /run/atlas/public 0755 root root - -"
        "d /run/atlas/environment-sockets 0700 root root - -"
        "d ${guestContractRoot} 0755 root root - -"
        "d /run/atlas/entry-users 0711 root root - -"
        "d /run/atlas/locks 0700 root root - -"
        "d /var/lib/incus/security/apparmor/profiles 0700 root root - -"
      ]
      ++ concatMap (
        name:
        let
          environment = cfg.environments.${name};
          user = loginUser name;
        in
        [
          "d ${loginHome environment} 0700 ${user} ${user} - -"
          "d /run/atlas/environment-sockets/${name} 0700 root root - -"
        ]
      ) environmentNames
      ++ [ "d ${builtins.dirOf ownerHomePath} 0711 root root - -" ]
      ++ lib.optionals (!btrfsStorage) ([
        "d ${ownerHomePath} 0700 ${toString cfg.owner.uid} ${toString cfg.owner.uid} - -"
      ])
      ++ concatMap (
        name:
        let
          volume = cfg.volumes.${name};
          parent = builtins.dirOf (volumePath volume);
        in
        [ "d ${parent} 0711 root root - -" ]
        ++ lib.optional (
          !btrfsStorage
        ) "d ${volumePath volume} 0700 ${toString cfg.owner.uid} ${toString cfg.owner.uid} - -"
      ) volumeNames;
    };

    users = {
      groups = mapAttrs' (
        name: environment: nameValuePair (loginUser name) { gid = environment.uid; }
      ) cfg.environments;

      users = mapAttrs' (
        name: environment:
        nameValuePair (loginUser name) {
          isNormalUser = true;
          uid = environment.uid;
          group = loginUser name;
          home = loginHome environment;
          createHome = false;
          shell = entryShells.${name};
          hashedPassword = "!";
        }
      ) cfg.environments;
    };
  };
}
