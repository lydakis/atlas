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
    ];

    virtualisation = {
      cores = 2;
      memorySize = 2048;
    };
  };

  testScript = ''
    import json
    import shlex

    start_all()

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
    assert contract["version"] == 5
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
    assert environment_entry["version"] == 3
    assert environment_entry["composition"]["declarative"] is True
    assert environment_entry["composition"]["runtimeCreation"] is False
    assert environment_entry["composition"]["disposableRoots"] is True
    assert environment_entry["composition"]["durableVolumes"] is True
    assert environment_entry["composition"]["persistentInstances"] is True
    assert environment_entry["composition"]["concurrentEntry"] is True
    assert environment_entry["identity"]["source"] == "unix-peer-credentials-and-anchored-cgroup"
    assert environment_entry["identity"]["callerAuthoredIdentityAccepted"] is False
    shared = environment_entry["environments"]["shared-dev"]
    assert shared["id"] == "11111111-1111-4111-8111-111111111111"
    assert shared["entry"]["loginUser"] == "atlas-shared-dev"
    assert shared["runtime"]["backend"] == "systemd-nspawn-service"
    assert shared["runtime"]["lifecycle"] == "disposable"
    assert shared["runtime"]["storageMax"] == "1G"
    assert shared["runtime"]["baseImage"]["distribution"] == "ubuntu"
    assert shared["volumes"] == [{
        "access": "read-write",
        "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "name": "projects",
        "target": "/home/agent/work",
    }]
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
    assert environment_entry["environments"]["personal-dev"]["git"]["config"]["user"]["email"] == "george@lydakis.me"
    assert environment_entry["environments"]["restricted"]["packages"] == {}
    projects = environment_entry["volumes"]["projects"]
    assert projects["durability"] == "host-durable"
    assert projects["hostPath"] == "/var/lib/atlas/volumes/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/data"

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
    assert doctor["result"]["storage"]["mode"] == "bounded-disposable-root-with-explicit-volumes"
    assert doctor["result"]["storage"]["bounded"] is True
    listed = json.loads(machine.succeed("atlas environment list --json"))
    assert [item["name"] for item in listed["result"]] == ["personal-dev", "restricted", "shared-dev"]
    machine.fail("atlas environment inspect self --json")

    shared_self = json.loads(entry("atlas-shared-dev", "atlas environment inspect self --json"))
    assert shared_self["result"]["name"] == "shared-dev"
    assert shared_self["result"]["uid"] == 23001
    restricted_self = json.loads(entry("atlas-restricted", "atlas environment inspect self --json"))
    assert restricted_self["result"]["name"] == "restricted"
    personal_self = json.loads(entry("atlas-personal-dev", "atlas environment inspect self --json"))
    assert personal_self["result"]["name"] == "personal-dev"
    machine.succeed(f"systemctl is-active {shlex.quote(shared['process']['serviceUnit'])}")
    machine.succeed("machinectl show atlas-shared-dev -p State --value | grep -Fx running")
    machine.fail("atlas --socket /run/atlas/control.sock environment reset shared-dev --json")

    assert entry("atlas-shared-dev", "git config --get user.email").strip() == "atlas@labblue.ai"
    assert entry("atlas-personal-dev", "git config --get user.email").strip() == "george@lydakis.me"
    entry("atlas-restricted", "command -v git", succeed=False)

    entry(
        "atlas-shared-dev",
        "git clone file://${testRepository} atlas && "
        "git config --global alias.proof status && "
        "cd atlas && echo shared-dev > environment.txt && git add environment.txt && "
        "git commit -m 'Prove Atlas Git environment'",
    )
    assert entry(
        "atlas-shared-dev",
        "cd atlas && git log -1 --format='%an|%ae'",
    ).strip() == "George Lydakis|atlas@labblue.ai"
    assert entry("atlas-shared-dev", "git config --global --get alias.proof").strip() == "status"
    entry("atlas-personal-dev", f"cat {shared['home']}/atlas/environment.txt", succeed=False)

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
        f"mkdir -p work/repo-a work/repo-b; echo {sentinel} > work/repo-a/environment-probe",
    )
    assert entry("atlas-shared-dev", "cat work/repo-a/environment-probe").strip() == sentinel
    assert entry("atlas-personal-dev", "cat work/repo-a/environment-probe").strip() == sentinel
    entry("atlas-restricted", "cat /home/agent/work/repo-a/environment-probe", succeed=False)

    assert entry("atlas-shared-dev", "id -u").strip() == "0"
    entry("atlas-shared-dev", "echo disposable > /etc/atlas-disposable-state")
    machine.fail("test -e /etc/atlas-disposable-state")

    package_result = entry(
        "atlas-shared-dev",
        "DEBIAN_FRONTEND=noninteractive apt-get install -y ${testPackage} >/tmp/atlas-apt.log && "
        "atlas-proof-tool",
    )
    assert package_result.strip() == "atlas-proof-tool-installed"
    assert entry("atlas-shared-dev", "atlas-proof-tool").strip() == "atlas-proof-tool-installed"
    entry("atlas-shared-dev", "test -f /usr/lib/systemd/system/atlas-proof-tool.service")
    entry("atlas-personal-dev", "command -v atlas-proof-tool", succeed=False)

    long_command = "echo active > work/repo-a/long-entry; sleep 300"
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
        "echo concurrent > work/repo-a/concurrent-entry; cat work/repo-a/concurrent-entry",
    )
    assert concurrent.strip() == "concurrent"

    reset = json.loads(machine.succeed("atlas environment reset shared-dev --json"))
    assert reset["ok"] is True
    assert reset["result"]["reset"] is True
    assert reset["result"]["preservedVolumes"] == ["projects"]
    machine.wait_until_fails(f"test -d /proc/{long_host_pid}", timeout=60)
    machine.execute("systemctl kill --kill-who=all --signal=KILL atlas-long-entry.service")
    machine.execute("systemctl stop --no-block atlas-long-entry.service")
    entry("atlas-shared-dev", "command -v atlas-proof-tool", succeed=False)
    entry("atlas-shared-dev", "test -e /etc/atlas-disposable-state", succeed=False)
    assert entry("atlas-shared-dev", "cat work/repo-a/environment-probe").strip() == sentinel
    assert entry("atlas-shared-dev", "cat work/repo-a/concurrent-entry").strip() == "concurrent"
    entry("atlas-shared-dev", "git config --global --get alias.proof", succeed=False)

    machine.fail("sudo -u atlas-shared-dev sudo -n true")

    allowed_users = machine.succeed("nix config show --json | jq -r '.\"allowed-users\".value | join(\" \")'").strip()
    trusted_users = machine.succeed("nix config show --json | jq -r '.\"trusted-users\".value | join(\" \")'").strip()
    assert allowed_users == "root"
    assert trusted_users == "root"

    def assert_shared_state():
        assert entry("atlas-shared-dev", "cat work/repo-a/environment-probe").strip() == sentinel

    assert_shared_state()
    machine.succeed("systemctl restart atlas-control.service")
    machine.wait_for_unit("atlas-control.service")
    assert_shared_state()
    baseline = machine.succeed("readlink -f /run/current-system").strip()
    updated = machine.succeed("readlink -f /run/current-system/specialisation/atlas-updated").strip()

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
  '';
}
