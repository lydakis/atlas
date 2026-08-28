{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.atlas.host;
  gitIni = pkgs.formats.gitIni { };
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
    optionalAttrs
    types
    unique
    ;

  environmentNames = builtins.attrNames cfg.environments;
  layerNames = builtins.attrNames cfg.environmentLayers;
  volumeNames = builtins.attrNames cfg.volumes;

  loginUser = name: "atlas-${name}";
  loginHome = environment: "/run/atlas/entry-users/${environment.id}";
  environmentStateParent = environment: "${toString cfg.dataRoot}/environments/${environment.id}";
  environmentRuntimeRoot = environment: "${environmentStateParent environment}/rootfs";
  environmentRuntimeReady = environment: "${environmentStateParent environment}/rootfs.ready";
  environmentSeed = environment: "${environmentStateParent environment}/seed";
  environmentSnapshots = environment: "${environmentStateParent environment}/snapshots";
  environmentLock = environment: "/run/atlas/locks/${environment.id}.lock";
  volumePath = volume: "${toString cfg.dataRoot}/volumes/${volume.id}/data";
  dataRootPersistent = cfg.dataRootPersistence == "reboot-persistent";
  btrfsStorage = cfg.storage.adapter == "btrfs-subvolume";
  escapedSliceSegment = name: lib.replaceStrings [ "-" ] [ "\\x2d" ] name;
  sliceName = name: "atlas-environments-${escapedSliceSegment name}";
  sliceUnit = name: "${sliceName name}.slice";
  environmentServiceName = name: "atlas-environment-${escapedSliceSegment name}";
  environmentServiceUnit = name: "${environmentServiceName name}.service";
  environmentCgroupPrefix =
    name: "/atlas.slice/atlas-environments.slice/${sliceUnit name}/${environmentServiceUnit name}";

  ubuntuArchitecture = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "amd64";
  ubuntuRootfs = pkgs.fetchurl {
    url = "https://partner-images.canonical.com/oci/noble/20260810/ubuntu-noble-oci-${ubuntuArchitecture}-root.tar.gz";
    hash =
      if pkgs.stdenv.hostPlatform.isAarch64 then
        "sha256-k6XLePgVlERrbyEzkNUqHzeCiN4TbDEfNpU476cul7U="
      else
        "sha256-qqeq73rxhbs1mvI151NLBYDlz3yfwn2010xIgfJ1JMw=";
  };
  baseImageRecord = {
    distribution = "ubuntu";
    release = "24.04";
    build = "20260810";
    architecture = ubuntuArchitecture;
    source = "canonical-oci-rootfs";
  };
  bootstrapTree = ''
    bootstrap_tree() {
      local target="$1"
      tar --extract --gzip --numeric-owner --file=${ubuntuRootfs} --directory="$target"
      install -d -m 0755 \
        "$target/etc/atlas" \
        "$target/etc/systemd/system" \
        "$target/home/agent" \
        "$target/home/agent/work" \
        "$target/run/atlas" \
        "$target/run/atlas-host-systemd" \
        "$target/usr/lib/systemd"
      sed -i -E 's#^(root:[^:]*:[^:]*:[^:]*:[^:]*):/root:#\1:/home/agent:#' \
        "$target/etc/passwd"
      ln -sfn /run/atlas-host-systemd/lib/systemd/systemd "$target/sbin/init"
      rm -rf -- "$target/usr/lib/systemd/system"
      install -d -m 0755 "$target/usr/lib/systemd/system"
      while IFS= read -r -d "" source_path; do
        relative_path="''${source_path#./}"
        install -d -m 0755 "$target/usr/lib/systemd/system/$relative_path"
      done < <(
        cd ${pkgs.systemd}/example/systemd/system
        find . -mindepth 1 -type d -print0
      )
      while IFS= read -r -d "" source_path; do
        relative_path="''${source_path#./}"
        ln -sfn \
          "/run/atlas-host-systemd/example/systemd/system/$relative_path" \
          "$target/usr/lib/systemd/system/$relative_path"
      done < <(
        cd ${pkgs.systemd}/example/systemd/system
        find . -mindepth 1 ! -type d -print0
      )
      ln -sfn /usr/lib/systemd/system/multi-user.target \
        "$target/etc/systemd/system/default.target"
    }
  '';
  seedBootstrapDigest = builtins.hashString "sha256" bootstrapTree;
  seedId = builtins.hashString "sha256" "${ubuntuRootfs}:${pkgs.systemd}:${seedBootstrapDigest}";

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
    inherit (volume) id owner;
    inherit name;
    hostPath = volumePath volume;
    durability = if dataRootPersistent then "host-durable" else "host-volatile";
  };
  volumeRecords = mapAttrs volumeRecord cfg.volumes;

  environmentVolumeRecords =
    environment:
    mapAttrsToList (name: mount: {
      inherit (mount) access target;
      inherit name;
      id = cfg.volumes.${name}.id;
    }) (lib.filterAttrs (name: _mount: hasAttr name cfg.volumes) environment.volumeMounts);

  environmentRecord = name: environment: {
    inherit (environment) id uid;
    inherit name;
    home = "/home/agent";
    variables = effectiveVariables environment;
    packages = effectivePackageNames environment;
    git.config = effectiveGitConfig environment;
    network = {
      mode = environment.networkMode;
      status = "degraded";
    };
    resources = environment.resources;
    runtime = {
      backend = "systemd-nspawn-service";
      lifecycle = "resettable";
      persistence = if dataRootPersistent then "until-explicit-reset" else "until-reset-or-host-reboot";
      resettable = true;
      rootHostPath = environmentRuntimeRoot environment;
      readyHostPath = environmentRuntimeReady environment;
      storage = {
        adapter = cfg.storage.adapter;
        copyOnWrite = btrfsStorage;
        snapshots = btrfsStorage;
      }
      // optionalAttrs btrfsStorage {
        seedHostPath = environmentSeed environment;
        snapshotsHostPath = environmentSnapshots environment;
        seed.id = seedId;
        seedPrepareCommand = "${seedPreparers.${name}}/bin/atlas-prepare-seed-${name}";
      };
      baseImage = baseImageRecord;
    };
    process = {
      cgroupPrefix = environmentCgroupPrefix name;
      serviceUnit = environmentServiceUnit name;
      sliceUnit = sliceUnit name;
    };
    volumes = environmentVolumeRecords environment;
    entry = {
      adapter = "fixed-login-to-persistent-nspawn";
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
    adapter = if btrfsStorage then "nixos-nspawn-btrfs-v0" else "nixos-nspawn-directory-v0";
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
      persistentInstances = true;
      concurrentEntry = true;
    };
    identity = {
      source = "unix-peer-credentials-and-anchored-cgroup";
      callerAuthoredIdentityAccepted = false;
    };
    rootIsolation = {
      mode = "systemd-nspawn-user-namespace";
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
      hostRecoveryReserve = false;
      rootPersistsAcrossReboot = dataRootPersistent;
      resettable = true;
      atRestEncryption = {
        mode = "none";
        status = "degraded";
      };
    };
    networkIsolation = {
      mode = "shared-host";
      status = "degraded";
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
      exec python3 ${../../src/atlas_control.py} "$@"
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
      ATLAS_CONTROL_SOCKET = "/run/atlas/control.sock";
      ATLAS_ENVIRONMENT_ID = environment.id;
      ATLAS_ENVIRONMENT_NAME = name;
      GIT_CONFIG_SYSTEM = toString gitConfigFiles.${name};
      HOME = "/home/agent";
      LOGNAME = "root";
      PATH = "/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${toolPath}";
      SHELL = toString environmentShell;
      USER = "root";
    };

  environmentArgumentLines =
    name: environment:
    let
      variables = environmentVariables name environment;
    in
    concatMapStringsSep "\n" (
      variable: "        ${lib.escapeShellArg "--setenv=${variable}=${variables.${variable}}"}"
    ) (builtins.attrNames variables);

  environmentAssignmentLines =
    name: environment:
    let
      variables = environmentVariables name environment;
    in
    concatMapStringsSep " \\\n" (
      variable: "          ${lib.escapeShellArg "${variable}=${variables.${variable}}"}"
    ) (builtins.attrNames variables);

  volumeArgumentLines =
    environment:
    concatMapStringsSep "\n" (
      volumeName:
      let
        mount = environment.volumeMounts.${volumeName};
        source = volumePath cfg.volumes.${volumeName};
        flag = if mount.access == "read-only" then "--bind-ro" else "--bind";
      in
      "        ${lib.escapeShellArg "${flag}=${source}:${mount.target}:idmap"}"
    ) (builtins.attrNames environment.volumeMounts);

  environmentDaemons = mapAttrs (
    name: environment:
    let
      runtimeRoot = environmentRuntimeRoot environment;
      environmentArguments = environmentArgumentLines name environment;
      volumeArguments = volumeArgumentLines environment;
    in
    pkgs.writeShellApplication {
      name = "atlas-environment-${name}";
      runtimeInputs = [ pkgs.systemd ];
      text = ''
        nspawn_arguments=(
          --quiet
          --settings=no
          --boot
          --notify-ready=yes
          --keep-unit
          --register=yes
          --machine=${lib.escapeShellArg "atlas-${name}"}
          --directory=${lib.escapeShellArg runtimeRoot}
          --private-users=pick
          --private-users-ownership=map
          --bind-ro=${pkgs.systemd}:/run/atlas-host-systemd
          --bind-ro=/nix/store:/nix/store
          --bind-ro=/etc/atlas:/etc/atlas
          --bind=/run/atlas/control.sock:/run/atlas/control.sock
        ${environmentArguments}
        ${volumeArguments}
        )
        exec systemd-nspawn "''${nspawn_arguments[@]}"
      '';
    }
  ) cfg.environments;

  seedPreparers = mapAttrs (
    name: environment:
    let
      stateParent = environmentStateParent environment;
      seedRoot = environmentSeed environment;
    in
    pkgs.writeShellApplication {
      name = "atlas-prepare-seed-${name}";
      runtimeInputs = [
        pkgs.btrfs-progs
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnused
        pkgs.gnutar
        pkgs.gzip
      ];
      text = ''
        refuse_mounts_below() {
          local managed_path="$1"
          local mount_target
          if [ ! -r /proc/self/mountinfo ]; then
            echo "Atlas could not inspect mount state" >&2
            return 1
          fi
          while IFS=' ' read -r _ _ _ _ mount_target _; do
            case "$mount_target" in
              "$managed_path"|"$managed_path"/*)
                echo "Atlas refused a lifecycle path with mounts below it" >&2
                return 1
                ;;
            esac
          done < /proc/self/mountinfo
        }

        delete_managed_tree() {
          local managed_path="$1"
          if [ ! -e "$managed_path" ]; then
            return 0
          fi
          if btrfs subvolume show "$managed_path" >/dev/null 2>&1; then
            btrfs subvolume delete --recursive --commit-after -- "$managed_path" >/dev/null
          else
            rm -rf -- "$managed_path"
          fi
        }

        make_private_path() {
          local pattern="$1"
          local temporary_path
          temporary_path="$(mktemp -d --tmpdir=${lib.escapeShellArg stateParent} "$pattern.XXXXXX")"
          rmdir -- "$temporary_path"
          printf '%s\n' "$temporary_path"
        }

        ${bootstrapTree}

        if [ -L ${lib.escapeShellArg stateParent} ] || [ ! -d ${lib.escapeShellArg stateParent} ]; then
          echo "Atlas refused an invalid environment state parent" >&2
          exit 1
        fi
        if [ -L ${lib.escapeShellArg seedRoot} ] || \
           { [ -e ${lib.escapeShellArg seedRoot} ] && \
             ! btrfs subvolume show ${lib.escapeShellArg seedRoot} >/dev/null 2>&1; }; then
          echo "Atlas refused an invalid Btrfs seed" >&2
          exit 1
        fi

        shopt -s nullglob
        private_seed_paths=(
          ${stateParent}/.deleting-seed.*
          ${stateParent}/.seed.*
        )
        shopt -u nullglob
        for private_seed_path in "''${private_seed_paths[@]}"; do
          if [ -L "$private_seed_path" ] || [ ! -d "$private_seed_path" ]; then
            echo "Atlas refused an invalid private seed path" >&2
            exit 1
          fi
          refuse_mounts_below "$private_seed_path"
          delete_managed_tree "$private_seed_path"
        done

        seed_matches=false
        if [ -d ${lib.escapeShellArg seedRoot} ] && \
           [ "$(cat ${lib.escapeShellArg "${seedRoot}/etc/atlas/seed-id"} 2>/dev/null || true)" = ${lib.escapeShellArg seedId} ] && \
           [ "$(btrfs property get -ts ${lib.escapeShellArg seedRoot} ro 2>/dev/null || true)" = ro=true ]; then
          seed_matches=true
        fi

        if [ "$seed_matches" = true ]; then
          exit 0
        fi

        temporary_seed="$(make_private_path .seed)"
        old_seed=""
        cleanup_seed() {
          if [ -n "$temporary_seed" ] && [ -e "$temporary_seed" ]; then
            delete_managed_tree "$temporary_seed"
          fi
        }
        trap cleanup_seed EXIT
        btrfs subvolume create "$temporary_seed" >/dev/null
        bootstrap_tree "$temporary_seed"
        printf '%s\n' ${lib.escapeShellArg seedId} > "$temporary_seed/etc/atlas/seed-id"
        btrfs property set -ts "$temporary_seed" ro true

        if [ -e ${lib.escapeShellArg seedRoot} ]; then
          old_seed="$(make_private_path .deleting-seed)"
          mv -T -- ${lib.escapeShellArg seedRoot} "$old_seed"
        fi
        if ! mv -T -- "$temporary_seed" ${lib.escapeShellArg seedRoot}; then
          if [ -n "$old_seed" ] && [ -e "$old_seed" ]; then
            mv -T -- "$old_seed" ${lib.escapeShellArg seedRoot}
          fi
          exit 1
        fi
        temporary_seed=""
        if [ -n "$old_seed" ] && [ -e "$old_seed" ]; then
          delete_managed_tree "$old_seed"
        fi
        trap - EXIT
      '';
    }
  ) cfg.environments;

  entryLaunchers = mapAttrs (
    name: environment:
    let
      stateParent = environmentStateParent environment;
      runtimeRoot = environmentRuntimeRoot environment;
      runtimeReady = environmentRuntimeReady environment;
      seedRoot = environmentSeed environment;
      snapshotsRoot = environmentSnapshots environment;
      environmentShell = environmentShells.${name};
      environmentAssignments = environmentAssignmentLines name environment;
      service = environmentServiceUnit name;
      cgroupPrefix = environmentCgroupPrefix name;
    in
    pkgs.writeShellApplication {
      name = "atlas-enter-${name}";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnused
        pkgs.gnutar
        pkgs.gzip
        pkgs.systemd
        pkgs.util-linux
      ]
      ++ lib.optionals btrfsStorage [ pkgs.btrfs-progs ];
      text = ''
                if [ "$#" -eq 1 ] && [ "$1" = "interactive" ]; then
                  command=(${environmentShell} -i)
                elif [ "$#" -eq 2 ] && [ "$1" = "command" ]; then
                  command=(${environmentShell} -c "$2")
                else
                  echo "Atlas entry launcher rejected unsupported arguments" >&2
                  exit 2
                fi
                storage_adapter=${lib.escapeShellArg cfg.storage.adapter}

                exec 9>${lib.escapeShellArg (environmentLock environment)}
                flock 9

                refuse_mounts_below() {
                  local managed_path="$1"
                  local mount_target
                  if [ ! -r /proc/self/mountinfo ]; then
                    echo "Atlas could not inspect mount state" >&2
                    return 1
                  fi
                  while IFS=' ' read -r _ _ _ _ mount_target _; do
                    case "$mount_target" in
                      "$managed_path"|"$managed_path"/*)
                        echo "Atlas refused a lifecycle path with mounts below it" >&2
                        return 1
                        ;;
                    esac
                  done < /proc/self/mountinfo
                }

                delete_managed_tree() {
                  local managed_path="$1"
                  if [ ! -e "$managed_path" ]; then
                    return 0
                  fi
                  if [ "$storage_adapter" = btrfs-subvolume ] && \
                     btrfs subvolume show "$managed_path" >/dev/null 2>&1; then
                    btrfs subvolume delete --recursive --commit-after -- "$managed_path" >/dev/null
                  else
                    rm -rf -- "$managed_path"
                  fi
                }

                make_private_path() {
                  local pattern="$1"
                  local temporary_path
                  temporary_path="$(mktemp -d --tmpdir=${lib.escapeShellArg stateParent} "$pattern.XXXXXX")"
                  rmdir -- "$temporary_path"
                  printf '%s\n' "$temporary_path"
                }

                ${bootstrapTree}

                if [ -L ${lib.escapeShellArg stateParent} ] || [ ! -d ${lib.escapeShellArg stateParent} ]; then
                  echo "Atlas refused an invalid environment state parent" >&2
                  exit 1
                fi
                if [ -L ${lib.escapeShellArg runtimeRoot} ] || \
                   { [ -e ${lib.escapeShellArg runtimeRoot} ] && [ ! -d ${lib.escapeShellArg runtimeRoot} ]; }; then
                  echo "Atlas refused an invalid environment runtime root" >&2
                  exit 1
                fi
                if [ -L ${lib.escapeShellArg runtimeReady} ] || \
                   { [ -e ${lib.escapeShellArg runtimeReady} ] && [ ! -f ${lib.escapeShellArg runtimeReady} ]; }; then
                  echo "Atlas refused an invalid environment readiness marker" >&2
                  exit 1
                fi
                if [ "$storage_adapter" = btrfs-subvolume ]; then
                  if [ -e ${lib.escapeShellArg runtimeRoot} ] && \
                     ! btrfs subvolume show ${lib.escapeShellArg runtimeRoot} >/dev/null 2>&1; then
                    echo "Atlas refused an environment root that is not a Btrfs subvolume" >&2
                    exit 1
                  fi
                  if [ -L ${lib.escapeShellArg seedRoot} ] || \
                     { [ -e ${lib.escapeShellArg seedRoot} ] && \
                       ! btrfs subvolume show ${lib.escapeShellArg seedRoot} >/dev/null 2>&1; }; then
                    echo "Atlas refused an invalid Btrfs seed" >&2
                    exit 1
                  fi
                  if [ -L ${lib.escapeShellArg snapshotsRoot} ] || \
                     { [ -e ${lib.escapeShellArg snapshotsRoot} ] && [ ! -d ${lib.escapeShellArg snapshotsRoot} ]; }; then
                    echo "Atlas refused an invalid snapshots directory" >&2
                    exit 1
                  fi
                  ${seedPreparers.${name}}/bin/atlas-prepare-seed-${name}
                fi

                if systemctl is-active --quiet ${lib.escapeShellArg service}; then
                  if [ ! -d ${lib.escapeShellArg runtimeRoot} ] || [ ! -f ${lib.escapeShellArg runtimeReady} ]; then
                    echo "Atlas refused an active environment with inconsistent runtime state" >&2
                    exit 1
                  fi
                else
                  refuse_mounts_below ${lib.escapeShellArg runtimeRoot}

                  shopt -s nullglob
                  private_paths=(
                    ${stateParent}/.deleting-*
                    ${stateParent}/.rootfs.*
                    ${stateParent}/.seed.*
                  )
                  shopt -u nullglob
                  for private_path in "''${private_paths[@]}"; do
                    if [ -L "$private_path" ] || [ ! -d "$private_path" ]; then
                      echo "Atlas refused an invalid private lifecycle path" >&2
                      exit 1
                    fi
                    refuse_mounts_below "$private_path"
                    delete_managed_tree "$private_path"
                  done

                  if { [ -e ${lib.escapeShellArg runtimeRoot} ] && [ ! -f ${lib.escapeShellArg runtimeReady} ]; } || \
                     { [ ! -e ${lib.escapeShellArg runtimeRoot} ] && [ -e ${lib.escapeShellArg runtimeReady} ]; }; then
                    delete_managed_tree ${lib.escapeShellArg runtimeRoot}
                    rm -f -- ${lib.escapeShellArg runtimeReady}
                  fi

                  if [ ! -f ${lib.escapeShellArg runtimeReady} ]; then
                    if [ "$storage_adapter" = btrfs-subvolume ]; then
                      temporary_root="$(make_private_path .rootfs)"
                      btrfs subvolume snapshot -- ${lib.escapeShellArg seedRoot} "$temporary_root" >/dev/null
                    else
                      temporary_root="$(mktemp -d --tmpdir=${lib.escapeShellArg stateParent} .rootfs.XXXXXX)"
                      bootstrap_tree "$temporary_root"
                    fi
                    cleanup() {
                      delete_managed_tree "$temporary_root"
                    }
                    trap cleanup EXIT
                    mv -T -- "$temporary_root" ${lib.escapeShellArg runtimeRoot}
                    install -m 0600 /dev/null ${lib.escapeShellArg runtimeReady}
                    trap - EXIT
                  fi

                  systemctl start ${lib.escapeShellArg service}
                fi
                flock -u 9

                leader="$(machinectl show ${lib.escapeShellArg "atlas-${name}"} --property=Leader --value)"
                if ! [[ "$leader" =~ ^[1-9][0-9]*$ ]]; then
                  echo "Atlas could not resolve the environment leader" >&2
                  exit 1
                fi

                control_group="$(systemctl show ${lib.escapeShellArg service} --property=ControlGroup --value)"
                case "$control_group" in
                  ${lib.escapeShellArg cgroupPrefix}|${lib.escapeShellArg "${cgroupPrefix}/"}*) ;;
                  *)
                    echo "Atlas refused an environment with an unexpected cgroup" >&2
                    exit 1
                    ;;
                esac
                session_cgroup="/sys/fs/cgroup''${control_group}/atlas-sessions"
                mkdir -p -- "$session_cgroup"
                printf '%s\n' "$$" > "$session_cgroup/cgroup.procs"

                exec nsenter \
                  --target "$leader" \
                  --user \
                  --mount \
                  --uts \
                  --ipc \
                  --net \
                  --pid \
                  --cgroup \
                  --wdns=/home/agent \
                  -- \
                  ${pkgs.coreutils}/bin/env -i \
        ${environmentAssignments} \
                  "''${command[@]}"
      '';
    }
  ) cfg.environments;

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
  volumeIds = map (name: cfg.volumes.${name}.id) volumeNames;
  allVariableNames = unique (
    concatMap (name: builtins.attrNames cfg.environmentLayers.${name}.variables) layerNames
    ++ concatMap (name: builtins.attrNames cfg.environments.${name}.variables) environmentNames
  );
  invalidVariableNames = filter (
    name: builtins.match "^[A-Za-z_][A-Za-z0-9_]*$" name == null
  ) allVariableNames;
  runtimeVariableNames = [
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
    filter (path: path == "/home/agent" || hasPrefix "${path}/" "/home/agent") allMountTargets
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
            owner = mkOption {
              type = types.str;
              default = "operator";
              description = "Durable ownership label; it is not a Linux username.";
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
            networkMode = mkOption {
              default = "shared-host";
              type = types.enum [ "shared-host" ];
            };
            resources = {
              cpuWeight = mkOption {
                default = 100;
                type = types.ints.between 1 10000;
              };
              ioWeight = mkOption {
                default = 100;
                type = types.ints.between 1 10000;
              };
              tasksMax = mkOption {
                default = 4096;
                type = types.ints.positive;
              };
              memoryMax = mkOption {
                default = null;
                type = types.nullOr types.str;
              };
            };
          };
        }
      );
      description = "Named persistent, resettable Atlas environment instances for the nspawn adapter.";
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
        assertion = length environmentUids == length (unique environmentUids);
        message = "Atlas environment UIDs must be unique";
      }
      {
        assertion = length volumeIds == length (unique volumeIds);
        message = "Atlas volume IDs must be unique";
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
      version = 5;
      adapter = if btrfsStorage then "nixos-nspawn-btrfs-v0" else "nixos-nspawn-directory-v0";
      baseImage = baseImageRecord;
      composition = doctor.composition;
      identity = doctor.identity;
      volumes = volumeRecords;
      environments = environmentRecords;
    };

    environment = {
      etc."atlas/control-contract.json".source = controlContractFile;
      shells = builtins.attrValues entryShells;
      systemPackages = [ atlasControl ] ++ lib.optionals btrfsStorage [ pkgs.btrfs-progs ];
    };

    security.sudo.extraRules = mapAttrsToList (name: _environment: {
      users = [ (loginUser name) ];
      commands = [
        {
          command = "${entryLaunchers.${name}}/bin/atlas-enter-${name}";
          options = [ "NOPASSWD" ];
        }
      ];
    }) cfg.environments;

    systemd = {
      services = {
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
              ''
            ) volumeNames}
          '';
        };

        atlas-host-contract = mkIf btrfsStorage {
          requires = [ "atlas-storage-prepare.service" ];
          after = [ "atlas-storage-prepare.service" ];
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
            ExecStart = "${atlasControl}/bin/atlas serve --management --systemctl ${pkgs.systemd}/bin/systemctl --btrfs ${pkgs.btrfs-progs}/bin/btrfs";
            User = "root";
            Group = "root";
            Slice = "atlas-control.slice";
            AmbientCapabilities = [
              "CAP_CHOWN"
              "CAP_DAC_OVERRIDE"
              "CAP_FSETID"
              "CAP_FOWNER"
            ]
            ++ lib.optional btrfsStorage "CAP_SYS_ADMIN";
            CapabilityBoundingSet = [
              "CAP_CHOWN"
              "CAP_DAC_OVERRIDE"
              "CAP_FSETID"
              "CAP_FOWNER"
            ]
            ++ lib.optional btrfsStorage "CAP_SYS_ADMIN";
            LockPersonality = true;
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectControlGroups = true;
            ProtectHome = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectSystem = "strict";
            ReadWritePaths = [
              "${toString cfg.dataRoot}/environments"
              "/run/atlas/locks"
            ];
            Restart = "on-failure";
            RestrictAddressFamilies = [ "AF_UNIX" ];
          };
        };
      }
      // mapAttrs' (
        name: environment:
        nameValuePair (environmentServiceName name) {
          description = "Persistent Atlas environment ${name}";
          requires = [ "atlas-control.socket" ];
          after = [ "atlas-control.socket" ];
          restartTriggers = [ environmentConfigFiles.${name} ];
          unitConfig.RequiresMountsFor = [ (environmentStateParent environment) ];
          serviceConfig = {
            Type = "notify";
            NotifyAccess = "all";
            ExecStart = "${environmentDaemons.${name}}/bin/atlas-environment-${name}";
            Slice = sliceUnit name;
            Delegate = true;
            KillMode = "mixed";
            Restart = "on-failure";
            RestartSec = "1s";
            TimeoutStartSec = "2min";
            TimeoutStopSec = "30s";
          };
        }
      ) cfg.environments;

      sockets = {
        atlas-control = {
          description = "Atlas public local control socket";
          wantedBy = [ "atlas-host.target" ];
          before = [ "atlas-host.target" ];
          socketConfig = {
            ListenStream = "/run/atlas/control.sock";
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
      };

      slices = mapAttrs' (
        name: environment:
        nameValuePair (sliceName name) {
          sliceConfig = {
            CPUWeight = environment.resources.cpuWeight;
            IOWeight = environment.resources.ioWeight;
            TasksMax = environment.resources.tasksMax;
          }
          // optionalAttrs (environment.resources.memoryMax != null) {
            MemoryMax = environment.resources.memoryMax;
          };
        }
      ) cfg.environments;

      tmpfiles.rules = [
        "d /run/atlas 0755 root root - -"
        "d /run/atlas/entry-users 0711 root root - -"
        "d /run/atlas/locks 0700 root root - -"
      ]
      ++ concatMap (
        name:
        let
          environment = cfg.environments.${name};
          user = loginUser name;
        in
        [
          "d ${loginHome environment} 0700 ${user} ${user} - -"
          "d ${environmentStateParent environment} 0700 root root - -"
          "d ${environmentSnapshots environment} 0700 root root - -"
        ]
      ) environmentNames
      ++ concatMap (
        name:
        let
          volume = cfg.volumes.${name};
          parent = builtins.dirOf (volumePath volume);
        in
        [ "d ${parent} 0711 root root - -" ]
        ++ lib.optional (!btrfsStorage) "d ${volumePath volume} 0700 root root - -"
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
