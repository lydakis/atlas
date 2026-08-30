{ pkgs, atlasModule }:
let
  testRepository =
    pkgs.runCommand "atlas-test-repository.git"
      {
        nativeBuildInputs = [ pkgs.git ];
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" work
        git init --bare "$out"
        git -C work init --initial-branch=main
        git -C work config user.name "Atlas Fixture"
        git -C work config user.email "fixture@example.invalid"
        echo "Atlas environment fixture" > work/README.md
        git -C work add README.md
        git -C work commit -m "Create fixture"
        git -C work remote add origin "$out"
        git -C work push origin main
        git --git-dir="$out" symbolic-ref HEAD refs/heads/main
      '';
  testPackage =
    pkgs.runCommand "atlas-proof-tool_1.0_all.deb"
      {
        nativeBuildInputs = [ pkgs.dpkg ];
      }
      ''
        mkdir -p package/DEBIAN package/usr/local/bin package/usr/lib/systemd/system
        cat > package/DEBIAN/control <<'EOF'
        Package: atlas-proof-tool
        Version: 1.0
        Architecture: all
        Maintainer: Atlas Test <atlas@example.invalid>
        Description: Offline package-manager fixture for the Atlas environment contract
        EOF
        cat > package/usr/local/bin/atlas-proof-tool <<'EOF'
        #!/bin/sh
        echo atlas-proof-tool-installed
        EOF
        chmod 0755 package/usr/local/bin/atlas-proof-tool
        cat > package/usr/lib/systemd/system/atlas-proof-tool.service <<'EOF'
        [Unit]
        Description=Atlas proof service

        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/atlas-proof-tool
        EOF
        dpkg-deb --root-owner-group --build package "$out"
      '';
in
pkgs.testers.runNixOSTest {
  name = "atlas-host-contract";

  # Docker Desktop on the development Mac does not expose KVM. Keep the test
  # runnable there through QEMU TCG while allowing native builders to use KVM.
  requiredFeatures.kvm = false;
  qemu.forceAccel = false;

  nodes.machine = {
    imports = [
      atlasModule
      ../configurations/spike-host.nix
      ../configurations/btrfs-vm-storage.nix
    ];

    specialisation.atlas-owner-home-detached.configuration = {
      system.nixos.tags = [ "atlas-owner-home-detached" ];
      atlas.host.environments.shared-dev.ownerHome = pkgs.lib.mkForce false;
    };

    virtualisation = {
      cores = 2;
      memorySize = 2048;
    };
  };

  testScript = ''
    import json
    import shlex

    # The storage contract includes an in-place reboot. Keep QEMU alive across
    # the guest reboot so the driver reconnects to the same persistent disk.
    machine.start(allow_reboot=True)

    machine.wait_for_unit("atlas-host.target")
    machine.wait_for_unit("tailscaled.service")
    machine.wait_for_unit("atlas-control.socket")
    machine.wait_for_unit("atlas-manage.socket")

    def entry(user, command, succeed=True):
        shell = machine.succeed(f"getent passwd {user} | cut -d: -f7").strip()
        invocation = f"sudo -u {user} {shell} -c {shlex.quote(command)}"
        if succeed:
            return machine.succeed(invocation)
        return machine.fail(invocation)

    contract = json.loads(machine.succeed("cat /etc/atlas/host-contract.json"))
    assert contract["version"] == 7
    assert contract["intent"]["primitives"] == ["host", "environment", "volume", "grant", "surface", "route"]
    assert contract["implementation"]["primitives"] == ["host", "environment", "volume"]
    assert contract["state"]["root"] == "/var/lib/atlas"
    assert contract["state"]["rootMode"] == "0711"
    assert contract["configuration"]["connectivity"]["openSshConfigured"] is False
    assert contract["configuration"]["connectivity"]["tailscale"]["adapterEnabled"] is True
    assert contract["configuration"]["connectivity"]["tailscale"]["sshRequested"] is True
    assert contract["configuration"]["connectivity"]["tailscale"]["enrollmentMode"] == "interactive"
    assert contract["configuration"]["nix"]["allowedUsers"] == ["root"]
    assert contract["configuration"]["nix"]["trustedUsers"] == ["root"]
    environment_entry = contract["configuration"]["environmentEntry"]
    assert environment_entry["version"] == 6
    assert environment_entry["composition"]["declarative"] is True
    assert environment_entry["composition"]["runtimeCreation"] is False
    assert environment_entry["composition"]["disposableRoots"] is False
    assert environment_entry["composition"]["resettableRoots"] is True
    assert environment_entry["composition"]["rebootPersistentRoots"] is True
    assert environment_entry["composition"]["durableVolumes"] is True
    assert environment_entry["composition"]["persistentInstances"] is True
    assert environment_entry["composition"]["concurrentEntry"] is True
    assert environment_entry["composition"]["durableOwnerHome"] is True
    assert environment_entry["composition"]["resettableHomePaths"] is True
    assert environment_entry["owner"] == {
        "home": "/home/owner",
        "homeStorage": {
            "durability": "host-durable",
            "hostPath": "/var/lib/atlas/volumes/dddddddd-dddd-4ddd-8ddd-dddddddddddd/data",
            "id": "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
        },
        "name": "owner",
        "uid": 1000,
    }
    assert environment_entry["identity"]["source"] == "unix-peer-credentials-and-anchored-cgroup"
    assert environment_entry["identity"]["callerAuthoredIdentityAccepted"] is False
    shared = environment_entry["environments"]["shared-dev"]
    personal = environment_entry["environments"]["personal-dev"]
    assert shared["id"] == "11111111-1111-4111-8111-111111111111"
    assert shared["entry"]["loginUser"] == "atlas-shared-dev"
    assert shared["runtime"]["backend"] == "systemd-nspawn-service"
    assert shared["runtime"]["lifecycle"] == "resettable"
    assert len(shared["runtime"]["ownerLayoutId"]) == 64
    assert shared["runtime"]["persistence"] == "until-explicit-reset"
    assert shared["runtime"]["storage"]["adapter"] == "btrfs-subvolume"
    assert shared["runtime"]["storage"]["copyOnWrite"] is True
    assert shared["runtime"]["storage"]["snapshots"] is True
    assert shared["runtime"]["storage"]["seedHostPath"].endswith("/seed")
    assert shared["runtime"]["storage"]["snapshotsHostPath"].endswith("/snapshots")
    assert len(shared["runtime"]["storage"]["seed"]["id"]) == 64
    assert shared["runtime"]["storage"]["seedPrepareCommand"].startswith("/nix/store/")
    assert shared["runtime"]["rootHostPath"] == "/var/lib/atlas/environments/11111111-1111-4111-8111-111111111111/rootfs"
    assert shared["runtime"]["baseImage"]["distribution"] == "ubuntu"
    assert shared["volumes"] == [{
        "access": "read-write",
        "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "name": "projects",
        "target": "/home/owner/Projects",
    }]
    assert shared["home"] == "/home/owner"
    assert shared["user"] == {
        "elevation": "passwordless-environment-sudo",
        "name": "owner",
        "uid": 1000,
    }
    assert shared["homeComposition"] == {
        "durable": True,
        "durableHostPath": "/var/lib/atlas/volumes/dddddddd-dddd-4ddd-8ddd-dddddddddddd/data",
        "resettablePaths": [".cache", ".config", ".local/bin", ".local/state"],
    }
    assert shared["variables"] == {
        "DEMO_API_ORIGIN": "https://example.invalid",
        "DEMO_BASE": "base",
        "DEMO_GENERATION": "baseline",
        "DEMO_NODE": "enabled",
        "DEMO_OVERRIDE": "instance",
    }
    assert shared["packages"] == {"git": "git", "python": "python3"}
    assert shared["git"]["config"]["user"] == {
        "email": "atlas@labblue.ai",
        "name": "George Lydakis",
    }
    assert personal["git"]["config"]["user"]["email"] == "george@lydakis.me"
    assert environment_entry["environments"]["restricted"]["packages"] == {}
    assert environment_entry["environments"]["restricted"]["homeComposition"] == {
        "durable": False,
        "resettablePaths": [],
    }
    projects = environment_entry["volumes"]["projects"]
    owner_home_path = environment_entry["owner"]["homeStorage"]["hostPath"]
    assert projects["durability"] == "host-durable"
    assert projects["hostPath"] == "/var/lib/atlas/volumes/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/data"
    machine.succeed(f"test $(stat -c %u {projects['hostPath']}) = 1000")
    machine.succeed(f"btrfs subvolume show {owner_home_path}")
    machine.succeed(f"test $(stat -c %u {owner_home_path}) = 1000")

    symlink_target = "/tmp/atlas-owner-home-symlink-target"
    machine.succeed(f"mkdir -p {symlink_target}; chown 1000:1000 {symlink_target}")
    for managed_path in (".cache", ".local"):
        candidate = f"{owner_home_path}/{managed_path}"
        machine.succeed(
            f"rm -rf {shlex.quote(candidate)}; "
            f"ln -s {shlex.quote(symlink_target)} {shlex.quote(candidate)}"
        )
        machine.fail("systemctl restart atlas-owner-home-prepare.service")
        machine.succeed(f"test -z \"$(find {symlink_target} -mindepth 1 -print -quit)\"")
        machine.succeed(
            f"rm {shlex.quote(candidate)}; mkdir {shlex.quote(candidate)}; "
            f"chown 1000:1000 {shlex.quote(candidate)}; "
            "systemctl restart atlas-owner-home-prepare.service"
        )

    machine.succeed("test $(stat -c %a /var/lib/atlas) = 711")
    for directory, metadata in contract["state"]["directories"].items():
        path = f"/var/lib/atlas/{directory}"
        machine.succeed(f"test $(stat -c %a {path}) = {metadata['mode'].lstrip('0')}")
        machine.succeed(f"test $(stat -c %U {path}) = {metadata['owner']}")
        machine.succeed(f"test $(stat -c %G {path}) = {metadata['group']}")
    machine.succeed("atlas-enroll --help | grep -F 'Interactively enroll this host in Tailscale'")
    machine.fail("systemctl is-enabled sshd.service")
    machine.fail("ss -ltnH 'sport = :22' | grep -q .")
    machine.succeed("systemctl show atlas-host-contract.service -p Slice --value | grep -Fx atlas-control.slice")
    machine.succeed("test $(stat -c %a /run/atlas/control.sock) = 666")
    machine.succeed("test $(stat -c %a /run/atlas/manage.sock) = 600")

    doctor = json.loads(machine.succeed("atlas doctor --json"))
    assert doctor["ok"] is True
    assert doctor["result"]["status"] == "experimental"
    assert doctor["result"]["composition"]["runtimeCreation"] is False
    assert doctor["result"]["networkIsolation"] == {"mode": "shared-host", "status": "degraded"}
    assert doctor["result"]["rootIsolation"]["mode"] == "systemd-nspawn-user-namespace"
    assert doctor["result"]["rootIsolation"]["hostRootShared"] is False
    assert doctor["result"]["storage"]["mode"] == "btrfs-copy-on-write-with-explicit-volumes"
    assert doctor["result"]["storage"]["bounded"] is False
    assert doctor["result"]["storage"]["copyOnWrite"] is True
    assert doctor["result"]["storage"]["snapshots"] is True
    assert doctor["result"]["storage"]["rollback"] is True
    assert doctor["result"]["storage"]["hostRecoveryReserve"] is False
    assert doctor["result"]["storage"]["rootPersistsAcrossReboot"] is True
    assert doctor["result"]["storage"]["resettable"] is True
    assert doctor["result"]["storage"]["atRestEncryption"] == {
        "mode": "none",
        "status": "degraded",
    }
    machine.succeed(
        "mkdir -p /tmp/atlas-shadow; "
        "printf '%s\\n' 'from pathlib import Path' 'Path(\"/tmp/atlas-shadow-executed\").touch()' > /tmp/atlas-shadow/atlas.py; "
        "cd /tmp/atlas-shadow; atlas doctor --json >/dev/null; "
        "test ! -e /tmp/atlas-shadow-executed"
    )
    listed = json.loads(machine.succeed("atlas environment list --json"))
    assert [item["name"] for item in listed["result"]] == ["personal-dev", "restricted", "shared-dev"]
    machine.fail("atlas environment inspect self --json")

    shared_state_parent = "/var/lib/atlas/environments/11111111-1111-4111-8111-111111111111"
    abandoned_ready = f"{shared_state_parent}/.rootfs-ready.interrupted"
    machine.succeed(f"printf 'pending\\n' > {abandoned_ready}")
    entry("atlas-shared-dev", "sudo -n touch /etc/atlas-cold-entry")
    machine.succeed(
        f"test -f {shlex.quote(shared['runtime']['rootHostPath'])}/etc/atlas-cold-entry"
    )
    shared_self = json.loads(entry("atlas-shared-dev", "atlas environment inspect self --json"))
    machine.fail(f"test -e {abandoned_ready}")
    assert shared_self["result"]["name"] == "shared-dev"
    assert shared_self["result"]["uid"] == 23001
    entry("atlas-restricted", "true")
    restricted_self = json.loads(entry("atlas-restricted", "atlas environment inspect self --json"))
    assert restricted_self["result"]["name"] == "restricted"
    entry("atlas-personal-dev", "true")
    personal_self = json.loads(entry("atlas-personal-dev", "atlas environment inspect self --json"))
    assert personal_self["result"]["name"] == "personal-dev"
    machine.succeed(f"systemctl is-active {shlex.quote(shared['process']['serviceUnit'])}")
    machine.succeed("machinectl show atlas-shared-dev -p State --value | grep -Fx running")
    machine.fail("atlas --socket /run/atlas/control.sock environment reset shared-dev --json")
    machine.fail(
        "atlas --socket /run/atlas/control.sock environment snapshot list shared-dev --json"
    )
    entry(
        "atlas-shared-dev",
        "atlas environment snapshot list shared-dev --json",
        succeed=False,
    )

    assert entry("atlas-shared-dev", "git config --get user.email").strip() == "atlas@labblue.ai"
    assert entry("atlas-personal-dev", "git config --get user.email").strip() == "george@lydakis.me"
    entry(
        "atlas-shared-dev",
        "test -s /etc/ssl/certs/ca-bundle.crt && test ! -L /etc/ssl/certs/ca-bundle.crt && "
        "test -s /etc/ssl/certs/ca-certificates.crt && test ! -L /etc/ssl/certs/ca-certificates.crt",
    )
    retired_ca_bundle = "/nix/store/00000000000000000000000000000000-retired-cacert/etc/ssl/certs/ca-bundle.crt"
    machine.succeed(
        f"ln -sfn {retired_ca_bundle} {shared['runtime']['rootHostPath']}/etc/ssl/certs/ca-bundle.crt; "
        f"ln -sfn {retired_ca_bundle} {shared['runtime']['rootHostPath']}/etc/ssl/certs/ca-certificates.crt"
    )
    entry(
        "atlas-shared-dev",
        "test -s /etc/ssl/certs/ca-bundle.crt && test ! -L /etc/ssl/certs/ca-bundle.crt && "
        "test -s /etc/ssl/certs/ca-certificates.crt && test ! -L /etc/ssl/certs/ca-certificates.crt",
    )
    entry("atlas-restricted", "command -v git", succeed=False)

    entry(
        "atlas-shared-dev",
        "mkdir -p Developer .config/atlas && "
        "git clone file://${testRepository} Developer/atlas && "
        "git config --global alias.proof status && "
        "echo shared-dev > .config/atlas/environment.txt && "
        "cd Developer/atlas && echo shared-dev > environment.txt && git add environment.txt && "
        "git commit -m 'Prove Atlas Git environment'",
    )
    assert entry(
        "atlas-shared-dev",
        "cd Developer/atlas && git log -1 --format='%an|%ae'",
    ).strip() == "George Lydakis|atlas@labblue.ai"
    assert entry("atlas-shared-dev", "git config --global --get alias.proof").strip() == "status"
    assert entry("atlas-personal-dev", "cat Developer/atlas/environment.txt").strip() == "shared-dev"
    entry("atlas-personal-dev", "cat .config/atlas/environment.txt", succeed=False)

    noninteractive = entry(
        "atlas-shared-dev",
        "printf '%s|%s|%s|%s' \"$ATLAS_ENVIRONMENT_NAME\" \"$DEMO_BASE\" \"$DEMO_NODE\" \"$DEMO_OVERRIDE\"",
    ).strip()
    assert noninteractive == "shared-dev|base|enabled|instance"

    shared_shell = machine.succeed("getent passwd atlas-shared-dev | cut -d: -f7").strip()
    machine.succeed(
        "printf '%s\\n' "
        "'echo \"INTERACTIVE=$ATLAS_ENVIRONMENT_NAME|$DEMO_OVERRIDE\"' "
        "exit > /tmp/atlas-interactive-input"
    )
    interactive = machine.succeed(
        f"script -qefc 'sudo -u atlas-shared-dev {shared_shell}' /dev/null "
        "< /tmp/atlas-interactive-input"
    )
    assert "INTERACTIVE=shared-dev|instance" in interactive

    nested_shared = entry(
        "atlas-shared-dev",
        "$SHELL -ic 'printf \"NESTED=%s|%s\\n\" \"$ATLAS_ENVIRONMENT_NAME\" \"$DEMO_OVERRIDE\"; "
        "command -v git; command -v curl || true'",
    )
    assert "NESTED=shared-dev|instance" in nested_shared
    assert "/bin/git" in nested_shared
    assert "/bin/curl" not in nested_shared
    nested_restricted = entry(
        "atlas-restricted",
        "$SHELL -ic 'command -v git || true; command -v curl || true'",
    )
    assert "/bin/git" not in nested_restricted
    assert "/bin/curl" not in nested_restricted

    sentinel = "durable-project-state"
    entry(
        "atlas-shared-dev",
        f"mkdir -p Projects/repo-a Projects/repo-b; echo {sentinel} > Projects/repo-a/environment-probe",
    )
    assert entry("atlas-shared-dev", "cat Projects/repo-a/environment-probe").strip() == sentinel
    assert entry("atlas-personal-dev", "cat Projects/repo-a/environment-probe").strip() == sentinel
    entry("atlas-restricted", "cat /home/owner/Projects/repo-a/environment-probe", succeed=False)

    restricted = environment_entry["environments"]["restricted"]
    restricted_root = restricted["runtime"]["rootHostPath"]
    restricted_saved_root = f"{restricted_root}.saved"
    projects_path = projects["hostPath"]
    machine.succeed(f"systemctl stop {shlex.quote(restricted['process']['serviceUnit'])}")
    machine.succeed(f"mv {restricted_root} {restricted_saved_root}")
    machine.succeed(f"ln -s {projects_path} {restricted_root}")
    entry("atlas-restricted", "true", succeed=False)
    assert machine.succeed(f"cat {projects_path}/repo-a/environment-probe").strip() == sentinel
    machine.succeed(f"rm {restricted_root}; mv {restricted_saved_root} {restricted_root}")
    entry("atlas-restricted", "true")

    restricted_stale_mount = f"{restricted_root}/stale-project-mount"
    machine.succeed(f"systemctl stop {shlex.quote(restricted['process']['serviceUnit'])}")
    machine.succeed(f"mkdir -p {shlex.quote(restricted_stale_mount)}")
    machine.succeed(
        f"mount --bind {shlex.quote(projects_path)} {shlex.quote(restricted_stale_mount)}"
    )
    entry("atlas-restricted", "true", succeed=False)
    machine.fail(f"systemctl is-active {shlex.quote(restricted['process']['serviceUnit'])}")
    assert machine.succeed(f"cat {projects_path}/repo-a/environment-probe").strip() == sentinel
    machine.succeed(f"umount {shlex.quote(restricted_stale_mount)}")
    machine.succeed(f"rmdir {shlex.quote(restricted_stale_mount)}")
    entry("atlas-restricted", "true")

    restricted_ready = restricted["runtime"]["readyHostPath"]
    machine.succeed(f"systemctl stop {shlex.quote(restricted['process']['serviceUnit'])}")
    machine.succeed(
        f"rm -f {shlex.quote(restricted_root)}/etc/atlas/owner-layout-id && "
        f"ln -s {shlex.quote(restricted_ready)} "
        f"{shlex.quote(restricted_root)}/etc/atlas/owner-layout-id"
    )
    forged_snapshot = json.loads(
        machine.succeed(
            "atlas environment snapshot create restricted forged-layout --json || true"
        )
    )
    assert forged_snapshot["ok"] is False
    assert forged_snapshot["error"]["code"] == "reset_required"
    machine.succeed(f"systemctl stop {shlex.quote(restricted['process']['serviceUnit'])}")
    machine.succeed(f"echo stale-owner-layout > {shlex.quote(restricted_ready)}")
    entry("atlas-restricted", "true", succeed=False)
    repaired_restricted = json.loads(
        machine.succeed("atlas environment reset restricted --json")
    )
    assert repaired_restricted["ok"] is True
    assert repaired_restricted["result"]["preservedOwnerHome"] is False
    machine.succeed(f"btrfs subvolume show {shlex.quote(restricted_root)}")
    assert machine.succeed(f"cat {shlex.quote(restricted_ready)}").strip() == restricted["runtime"]["ownerLayoutId"]
    entry("atlas-restricted", "true")

    assert entry("atlas-shared-dev", "id -u").strip() == "1000"
    assert entry("atlas-shared-dev", "id -un").strip() == "owner"
    assert entry("atlas-shared-dev", "printf '%s|%s|%s' \"$HOME\" \"$USER\" \"$LOGNAME\"").strip() == "/home/owner|owner|owner"
    assert entry("atlas-shared-dev", "command -v sudo").strip() == "/usr/bin/sudo"
    assert entry("atlas-shared-dev", "dpkg-query -S /usr/bin/sudo").strip() == "sudo: /usr/bin/sudo"
    entry("atlas-shared-dev", "dpkg-query -s sudo | grep -qx 'Status: install ok installed'")
    entry("atlas-shared-dev", "test ! -e /usr/local/bin/sudo")
    entry("atlas-shared-dev", "test -z \"$(grep -F /nix/store /etc/pam.d/sudo || true)\"")
    entry("atlas-shared-dev", "test ! -e /usr/lib/atlas/bootstrap-packages")
    assert entry("atlas-shared-dev", "sudo -n id -u").strip() == "0"
    entry("atlas-shared-dev", "sudo -n sh -c 'echo persistent > /etc/atlas-persistent-state'")
    entry("atlas-shared-dev", "mkdir -p Documents .local/share; echo durable-home > Documents/persistent-home; echo durable-share > .local/share/persistent-share")
    entry(
        "atlas-shared-dev",
        "mkdir -p .cache/atlas .config/atlas .local/bin .local/state/atlas; "
        "echo resettable-cache > .cache/atlas/state; "
        "echo resettable-config > .config/atlas/state; "
        "echo resettable-bin > .local/bin/atlas-state; "
        "echo resettable-local-state > .local/state/atlas/state",
    )
    entry("atlas-restricted", "test -e /home/owner/Documents/persistent-home", succeed=False)
    entry("atlas-shared-dev", "sudo -n sh -c 'echo volatile > /run/atlas-volatile-state'")
    entry("atlas-personal-dev", "sudo -n sh -c 'echo reset-before-reentry > /etc/atlas-offline-reset-state'")
    entry("atlas-personal-dev", "mkdir -p .config/atlas; echo personal-dev > .config/atlas/environment.txt")
    machine.fail("test -e /etc/atlas-persistent-state")

    package_result = entry(
        "atlas-shared-dev",
        "if ! sudo -n env DEBIAN_FRONTEND=noninteractive "
        "apt-get install -y ${testPackage} </dev/null >/tmp/atlas-apt.log 2>&1; then "
        "cat /tmp/atlas-apt.log >&2; exit 1; fi; "
        "atlas-proof-tool",
    )
    assert package_result.strip() == "atlas-proof-tool-installed"
    assert entry("atlas-shared-dev", "atlas-proof-tool").strip() == "atlas-proof-tool-installed"
    entry("atlas-shared-dev", "test -f /usr/lib/systemd/system/atlas-proof-tool.service")
    entry("atlas-personal-dev", "command -v atlas-proof-tool", succeed=False)

    shared_root = shared["runtime"]["rootHostPath"]
    state_parent = shared_root.rsplit("/", 1)[0]
    machine.succeed(f"test -d {shared_root}")
    machine.succeed(
        f"test $(findmnt -n -o UUID -T {shared_root}) = $(findmnt -n -o UUID -T /var/lib/atlas)"
    )
    machine.fail(f"mountpoint -q {shared_root}")
    machine.succeed("test $(stat -f -c %T /var/lib/atlas) = btrfs")
    machine.succeed(f"btrfs subvolume show {shared_root}")
    machine.succeed(f"btrfs subvolume show {shared['runtime']['storage']['seedHostPath']}")
    machine.succeed(f"btrfs subvolume show {projects_path}")
    assert entry("atlas-shared-dev", "readlink /sbin/init").strip() == "/run/atlas-host-systemd/lib/systemd/systemd"
    entry("atlas-shared-dev", "test -x /sbin/init")
    journald_unit = "/usr/lib/systemd/system/systemd-journald.service"
    assert entry("atlas-shared-dev", f"readlink {journald_unit}").strip() == (
        "/run/atlas-host-systemd/example/systemd/system/systemd-journald.service"
    )
    entry("atlas-shared-dev", f"test -f {journald_unit}")

    snapshot = json.loads(
        machine.succeed("atlas environment snapshot create shared-dev before-restore --json")
    )
    assert snapshot["result"]["created"] is True
    assert snapshot["result"]["snapshot"] == "before-restore"
    snapshot_path = f"{state_parent}/snapshots/before-restore"
    machine.succeed(f"btrfs subvolume show {snapshot_path}")
    machine.succeed(f"test $(btrfs property get -ts {snapshot_path} ro | cut -d= -f2) = true")

    machine.reboot()
    machine.wait_for_unit("atlas-host.target")
    machine.wait_for_unit("atlas-control.socket")
    machine.wait_for_unit("atlas-manage.socket")
    machine.fail(f"systemctl is-active {shlex.quote(shared['process']['serviceUnit'])}")
    machine.fail(f"systemctl is-active {shlex.quote(personal['process']['serviceUnit'])}")
    assert entry("atlas-personal-dev", "cat .config/atlas/environment.txt").strip() == "personal-dev"
    personal_root = personal["runtime"]["rootHostPath"]
    personal_ready = personal["runtime"]["readyHostPath"]
    personal_seed = personal["runtime"]["storage"]["seedHostPath"]
    expected_personal_seed_id = personal["runtime"]["storage"]["seed"]["id"]
    personal_seed_orphan = f"{personal['runtime']['rootHostPath'].rsplit('/', 1)[0]}/.seed.interrupted-reset"
    machine.succeed(
        f"btrfs property set -ts {personal_seed} ro false; "
        f"echo {'0' * 64} > {personal_seed}/etc/atlas/seed-id; "
        f"touch {personal_seed}/etc/atlas/stale-seed; "
        f"btrfs property set -ts {personal_seed} ro true; "
        f"btrfs subvolume create {personal_seed_orphan}"
    )
    machine.succeed(
        f"btrfs subvolume delete {shlex.quote(personal_root)}; "
        f"rm -f {shlex.quote(personal_ready)}"
    )
    offline_reset = json.loads(machine.succeed("atlas environment reset personal-dev --json"))
    assert offline_reset["ok"] is True
    machine.succeed(f"btrfs subvolume show {shlex.quote(personal_root)}")
    machine.succeed(f"test -f {shlex.quote(personal_ready)}")
    assert machine.succeed(f"cat {personal_seed}/etc/atlas/seed-id").strip() == expected_personal_seed_id
    machine.fail(f"test -e {personal_seed}/etc/atlas/stale-seed")
    machine.fail(f"test -e {personal_seed_orphan}")
    entry("atlas-personal-dev", "test -e /etc/atlas-offline-reset-state", succeed=False)
    assert entry("atlas-shared-dev", "cat /etc/atlas-persistent-state").strip() == "persistent"
    assert entry("atlas-shared-dev", "cat Documents/persistent-home").strip() == "durable-home"
    assert entry("atlas-shared-dev", "cat .local/share/persistent-share").strip() == "durable-share"
    assert entry("atlas-shared-dev", "cat .cache/atlas/state").strip() == "resettable-cache"
    assert entry("atlas-shared-dev", "cat .config/atlas/state").strip() == "resettable-config"
    assert entry("atlas-shared-dev", "cat .local/bin/atlas-state").strip() == "resettable-bin"
    assert entry("atlas-shared-dev", "cat .local/state/atlas/state").strip() == "resettable-local-state"
    assert entry("atlas-personal-dev", "cat Documents/persistent-home").strip() == "durable-home"
    entry("atlas-personal-dev", "test -e .config/atlas/environment.txt", succeed=False)
    assert entry("atlas-shared-dev", "atlas-proof-tool").strip() == "atlas-proof-tool-installed"
    entry("atlas-shared-dev", "test -e /run/atlas-volatile-state", succeed=False)
    assert entry("atlas-shared-dev", "cat Projects/repo-a/environment-probe").strip() == sentinel

    machine.succeed(f"btrfs subvolume show {snapshot_path}")
    machine.succeed(f"test $(btrfs property get -ts {snapshot_path} ro | cut -d= -f2) = true")
    listed_snapshots = json.loads(
        machine.succeed("atlas environment snapshot list shared-dev --json")
    )
    assert listed_snapshots["result"]["snapshots"] == ["before-restore"]

    entry("atlas-shared-dev", "sudo -n sh -c 'echo after-snapshot > /etc/atlas-after-snapshot'")
    entry("atlas-shared-dev", "echo durable-after-snapshot > Projects/repo-a/after-snapshot")
    entry("atlas-shared-dev", "echo owner-home-after-snapshot > Documents/after-snapshot")
    restored = json.loads(
        machine.succeed("atlas environment snapshot restore shared-dev before-restore --json")
    )
    assert restored["result"]["restored"] is True
    assert restored["result"]["preservedOwnerHome"] is True
    entry("atlas-shared-dev", "test -e /etc/atlas-after-snapshot", succeed=False)
    assert entry("atlas-shared-dev", "cat Projects/repo-a/after-snapshot").strip() == "durable-after-snapshot"
    assert entry("atlas-shared-dev", "cat Documents/after-snapshot").strip() == "owner-home-after-snapshot"
    assert entry("atlas-shared-dev", "atlas-proof-tool").strip() == "atlas-proof-tool-installed"

    deleted_snapshot = json.loads(
        machine.succeed("atlas environment snapshot delete shared-dev before-restore --json")
    )
    assert deleted_snapshot["result"]["deleted"] is True
    machine.fail(f"test -e {snapshot_path}")

    entry(
        "atlas-shared-dev",
        "sudo -n ${pkgs.btrfs-progs}/bin/btrfs subvolume create /opt/atlas-nested && "
        "sudo -n sh -c 'echo nested-state > /opt/atlas-nested/state'",
    )
    nested_snapshot = json.loads(
        machine.succeed(
            "atlas environment snapshot create shared-dev nested-root --json || true"
        )
    )
    assert nested_snapshot["ok"] is False
    assert nested_snapshot["error"]["code"] == "unsupported"
    assert entry("atlas-shared-dev", "cat /opt/atlas-nested/state").strip() == "nested-state"

    long_command = "echo active > Projects/repo-a/long-entry; sleep 300"
    machine.succeed(
        "systemd-run --unit=atlas-long-entry --property=User=atlas-shared-dev -- "
        f"{shared_shell} -c {shlex.quote(long_command)}"
    )
    machine.wait_until_succeeds(
        "test $(cat /var/lib/atlas/volumes/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/data/repo-a/long-entry) = active"
    )
    long_host_pid = machine.wait_until_succeeds(
        "for pid in $(pgrep -x sleep); do "
        f"grep -Fq {shlex.quote(shared['process']['cgroupPrefix'])} /proc/$pid/cgroup && "
        "echo $pid && exit 0; "
        "done; exit 1"
    ).strip()
    concurrent = entry(
        "atlas-shared-dev",
        "echo concurrent > Projects/repo-a/concurrent-entry; cat Projects/repo-a/concurrent-entry",
    )
    assert concurrent.strip() == "concurrent"

    reset_orphan = f"{state_parent}/.rootfs.interrupted-reset"
    reset_seed_orphan = f"{state_parent}/.seed.interrupted-reset"
    machine.succeed(f"mkdir -p {reset_orphan}; echo partial > {reset_orphan}/state")
    machine.succeed(f"btrfs subvolume create {reset_seed_orphan}")

    reset = json.loads(machine.succeed("atlas environment reset shared-dev --json"))
    assert reset["ok"] is True
    assert reset["result"]["reset"] is True
    assert reset["result"]["preservedOwnerHome"] is True
    assert reset["result"]["preservedVolumes"] == ["projects"]
    machine.wait_until_fails(f"test -d /proc/{long_host_pid}", timeout=60)
    machine.fail(f"test -e {reset_orphan}")
    machine.fail(f"test -e {reset_seed_orphan}")
    machine.execute("systemctl kill --kill-who=all --signal=KILL atlas-long-entry.service")
    machine.execute("systemctl stop --no-block atlas-long-entry.service")
    entry_orphan = f"{state_parent}/.rootfs.interrupted-entry"
    entry_seed_orphan = f"{state_parent}/.seed.interrupted-entry"
    machine.succeed(f"mkdir -p {entry_orphan}; echo partial > {entry_orphan}/state")
    machine.succeed(f"btrfs subvolume create {entry_seed_orphan}")
    entry("atlas-shared-dev", "command -v atlas-proof-tool", succeed=False)
    machine.fail(f"test -e {entry_orphan}")
    machine.fail(f"test -e {entry_seed_orphan}")
    entry("atlas-shared-dev", "test -e /opt/atlas-nested", succeed=False)
    entry("atlas-shared-dev", "test -e /etc/atlas-persistent-state", succeed=False)
    assert entry("atlas-shared-dev", "cat Documents/persistent-home").strip() == "durable-home"
    assert entry("atlas-shared-dev", "cat .local/share/persistent-share").strip() == "durable-share"
    entry("atlas-shared-dev", "test -e .cache/atlas/state", succeed=False)
    entry("atlas-shared-dev", "test -e .config/atlas/state", succeed=False)
    entry("atlas-shared-dev", "test -e .local/bin/atlas-state", succeed=False)
    entry("atlas-shared-dev", "test -e .local/state/atlas/state", succeed=False)
    entry("atlas-shared-dev", "test -e .config/atlas/environment.txt", succeed=False)
    entry("atlas-personal-dev", "test -e .config/atlas/environment.txt", succeed=False)
    assert entry("atlas-shared-dev", "cat Projects/repo-a/environment-probe").strip() == sentinel
    assert entry("atlas-shared-dev", "cat Projects/repo-a/concurrent-entry").strip() == "concurrent"
    entry("atlas-shared-dev", "git config --global --get alias.proof", succeed=False)

    machine.fail("sudo -u atlas-shared-dev sudo -n true")

    allowed_users = machine.succeed("nix config show --json | jq -r '.\"allowed-users\".value | join(\" \")'").strip()
    trusted_users = machine.succeed("nix config show --json | jq -r '.\"trusted-users\".value | join(\" \")'").strip()
    assert allowed_users == "root"
    assert trusted_users == "root"

    entry("atlas-shared-dev", "sudo -n sh -c 'echo update-persistent > /etc/atlas-update-state'")

    def assert_shared_state():
        assert entry("atlas-shared-dev", "cat Projects/repo-a/environment-probe").strip() == sentinel
        assert entry("atlas-shared-dev", "cat /etc/atlas-update-state").strip() == "update-persistent"

    assert_shared_state()
    machine.succeed("systemctl restart atlas-control.service")
    machine.wait_for_unit("atlas-control.service")
    assert_shared_state()
    baseline = machine.succeed("readlink -f /run/current-system").strip()
    updated = machine.succeed("readlink -f /run/current-system/specialisation/atlas-updated").strip()
    owner_home_detached = machine.succeed(
        "readlink -f /run/current-system/specialisation/atlas-owner-home-detached"
    ).strip()

    machine.succeed(f"{updated}/bin/switch-to-configuration test")
    machine.succeed("grep -Fx updated /etc/atlas-spike-generation")
    updated_inspect = json.loads(machine.succeed("atlas environment inspect shared-dev --json"))
    assert updated_inspect["result"]["variables"]["DEMO_GENERATION"] == "updated"
    assert entry("atlas-shared-dev", "printf %s \"$DEMO_GENERATION\"").strip() == "updated"
    assert_shared_state()

    machine.succeed(f"{baseline}/bin/switch-to-configuration test")
    machine.succeed("grep -Fx baseline /etc/atlas-spike-generation")
    baseline_inspect = json.loads(machine.succeed("atlas environment inspect shared-dev --json"))
    assert baseline_inspect["result"]["variables"]["DEMO_GENERATION"] == "baseline"
    assert entry("atlas-shared-dev", "printf %s \"$DEMO_GENERATION\"").strip() == "baseline"
    assert_shared_state()

    baseline_layout_id = baseline_inspect["result"]["runtime"]["ownerLayoutId"]
    machine.succeed(f"{owner_home_detached}/bin/switch-to-configuration test")
    detached_inspect = json.loads(machine.succeed("atlas environment inspect shared-dev --json"))
    assert detached_inspect["result"]["homeComposition"]["durable"] is False
    assert detached_inspect["result"]["runtime"]["ownerLayoutId"] != baseline_layout_id
    entry("atlas-shared-dev", "true", succeed=False)
    assert entry("atlas-personal-dev", "cat Documents/persistent-home").strip() == "durable-home"
    detached_reset = json.loads(machine.succeed("atlas environment reset shared-dev --json"))
    assert detached_reset["result"]["preservedOwnerHome"] is False
    entry("atlas-shared-dev", "test -e Documents/persistent-home", succeed=False)
    assert entry("atlas-shared-dev", "cat Projects/repo-a/environment-probe").strip() == sentinel

    machine.succeed(f"{baseline}/bin/switch-to-configuration test")
    restored_home_inspect = json.loads(machine.succeed("atlas environment inspect shared-dev --json"))
    assert restored_home_inspect["result"]["homeComposition"]["durable"] is True
    assert restored_home_inspect["result"]["runtime"]["ownerLayoutId"] == baseline_layout_id
    entry("atlas-shared-dev", "true", succeed=False)
    restored_home_reset = json.loads(machine.succeed("atlas environment reset shared-dev --json"))
    assert restored_home_reset["result"]["preservedOwnerHome"] is True
    assert entry("atlas-shared-dev", "cat Documents/persistent-home").strip() == "durable-home"
  '';
}
