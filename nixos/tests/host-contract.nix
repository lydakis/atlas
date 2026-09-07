{ pkgs, atlasModule }:
let
  testPackage =
    pkgs.runCommand "atlas-proof-tool_1.0_all.deb"
      {
        nativeBuildInputs = [ pkgs.dpkg ];
      }
      ''
        mkdir -p package/DEBIAN package/usr/local/bin
        cat > package/DEBIAN/control <<'EOF'
        Package: atlas-proof-tool
        Version: 1.0
        Architecture: all
        Maintainer: Atlas Test <atlas@example.invalid>
        Description: Offline package-manager fixture for the Atlas Incus contract
        EOF
        cat > package/usr/local/bin/atlas-proof-tool <<'EOF'
        #!/bin/sh
        echo atlas-proof-tool-installed
        EOF
        chmod 0755 package/usr/local/bin/atlas-proof-tool
        dpkg-deb --root-owner-group --build package "$out"
      '';
in
pkgs.testers.runNixOSTest {
  name = "atlas-host-contract";

  requiredFeatures.kvm = false;
  qemu.forceAccel = false;

  nodes.machine = {
    imports = [
      atlasModule
      ../configurations/spike-host.nix
      ../configurations/btrfs-vm-storage.nix
    ];

    virtualisation = {
      cores = 2;
      memorySize = 4096;
    };
  };

  testScript = ''
    import json
    import shlex

    serial_stdout_off()
    machine.start(allow_reboot=True)
    machine.wait_for_unit("incus.service")
    machine.wait_for_unit("incus-preseed.service")
    try:
        machine.wait_until_succeeds(
            "systemctl is-active atlas-host.target", timeout=600
        )
    except Exception:
        machine.log(machine.execute("systemctl --no-pager --full --failed")[1])
        machine.log(
            machine.execute(
                "systemctl --no-pager --full status atlas-host.target "
                "atlas-storage-prepare.service atlas-owner-home-prepare.service "
                "atlas-incus-image.service atlas-incus-network-policy.service "
                "'atlas-environment-*.service'"
            )[1]
        )
        machine.log(
            machine.execute(
                "journalctl --no-pager -b -u atlas-host.target "
                "-u atlas-storage-prepare.service -u atlas-owner-home-prepare.service "
                "-u atlas-incus-image.service -u atlas-incus-network-policy.service "
                "-u 'atlas-environment-*.service'"
            )[1]
        )
        raise
    machine.wait_for_unit("atlas-control.socket")
    machine.wait_for_unit("atlas-manage.socket")
    with subtest("Incus requires the data mount before startup"):
        for property in ("Requires", "After"):
            dependencies = machine.succeed(
                f"systemctl show incus.service -p {property} --value"
            ).split()
            assert "var-lib-atlas.mount" in dependencies
        machine.succeed("mountpoint /var/lib/atlas")

    with subtest("management capabilities are explicitly restricted"):
        machine.succeed("systemctl start atlas-manage.service")
        pid = machine.succeed(
            "systemctl show atlas-manage.service -p MainPID --value"
        ).strip()
        status = machine.succeed(f"cat /proc/{pid}/status")
        fields = dict(line.split(":", 1) for line in status.splitlines())
        expected = (1 << 2) | (1 << 21)  # DAC_READ_SEARCH and SYS_ADMIN
        for field in ("CapBnd", "CapPrm", "CapEff"):
            assert int(fields[field].strip(), 16) == expected, (field, fields[field])
        assert int(fields["CapAmb"].strip(), 16) == 0

    machine.succeed("test -S /run/atlas/public/control.sock")
    machine.fail("test -e /run/atlas/control.sock")

    def entry(user, command, succeeds=True):
        shell = machine.succeed(f"getent passwd {user} | cut -d: -f7").strip()
        invocation = f"sudo -u {user} {shell} -c {shlex.quote(command)}"
        if succeeds:
            return machine.succeed(invocation)
        return machine.fail(invocation)

    def wait_for_instance(name):
        machine.wait_until_succeeds(
            f"incus list {name} --format csv -c s | grep -Fx RUNNING",
            timeout=120,
        )
        machine.succeed(f"timeout -k 5 30 incus exec {name} -T -n -- true")

    for instance in ("atlas-shared-dev", "atlas-personal-dev", "atlas-restricted"):
        wait_for_instance(instance)

    with subtest("host contract selects Incus without a substrate fallback"):
        contract = json.loads(machine.succeed("cat /etc/atlas/host-contract.json"))
        environment_entry = contract["configuration"]["environmentEntry"]
        assert environment_entry["adapter"] == "nixos-incus-btrfs-v0"
        assert environment_entry["baseImage"] == {
            "architecture": "${if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "amd64"}",
            "build": "20260829",
            "contentId": environment_entry["baseImage"]["contentId"],
            "distribution": "ubuntu",
            "release": "24.04",
            "source": "linuxcontainers-incus-image",
        }
        assert len(environment_entry["baseImage"]["contentId"]) == 64
        shared = environment_entry["environments"]["shared-dev"]
        assert shared["runtime"]["backend"] == "incus-container"
        assert shared["runtime"]["instance"]["name"] == "atlas-shared-dev"
        assert shared["runtime"]["instance"]["verifyCommand"].startswith("/nix/store/")
        assert len(shared["runtime"]["layoutId"]) == 64
        assert shared["entry"]["adapter"] == "fixed-login-to-persistent-incus"
        assert environment_entry["identity"]["source"] == (
            "unix-peer-credentials-or-host-bound-environment-listener"
        )
        assert environment_entry["identity"]["callerAuthoredIdentityAccepted"] is False
        assert environment_entry["composition"]["persistentInstances"] is True
        assert environment_entry["composition"]["resettableRoots"] is True
        assert environment_entry["composition"]["durableOwnerHome"] is True
        machine.succeed("incus version | grep -F 7.0.1")
        machine.succeed("incus storage show atlas | grep -F 'driver: btrfs'")
        machine.succeed("grep -Fx Y /sys/module/apparmor/parameters/enabled")
        machine.succeed("systemctl is-active apparmor.service")
        machine.succeed("systemctl is-active atlas-incus-network-policy.service")
        machine.succeed("systemctl restart atlas-incus-image.service")
        machine.succeed("systemctl is-active atlas-incus-image.service")
        for instance in ("atlas-shared-dev", "atlas-personal-dev", "atlas-restricted"):
            assert json.loads(machine.succeed(
                f"incus query /1.0/instances/{instance}"
            ))["profiles"] == []
            assert machine.succeed(
                f"incus config get {instance} boot.autostart"
            ).strip() == "false"

    with subtest("noninteractive entry preserves streamed stdin"):
        shell = machine.succeed("getent passwd atlas-shared-dev | cut -d: -f7").strip()
        output = machine.succeed(
            f"printf 'streamed payload\\nsecond line\\n' | "
            f"timeout 60 sudo -u atlas-shared-dev {shell} -c cat"
        )
        assert output == "streamed payload\nsecond line\n"

    with subtest("fixed entry reaches the persistent instance as the owner"):
        assert entry("atlas-shared-dev", "id -u").strip() == "1000"
        assert entry("atlas-shared-dev", "id -un").strip() == "owner"
        assert entry(
            "atlas-shared-dev",
            "printf '%s|%s|%s' \"$HOME\" \"$USER\" \"$ATLAS_ENVIRONMENT_NAME\"",
        ).strip() == "/home/owner|owner|shared-dev"
        assert entry("atlas-shared-dev", "command -v git").startswith("/nix/store/")
        assert entry("atlas-shared-dev", "git config --get user.email").strip() == "atlas@labblue.ai"
        entry("atlas-shared-dev", "git config --global atlas.write-test writable")
        assert entry(
            "atlas-shared-dev", "git config --global --get atlas.write-test"
        ).strip() == "writable"
        assert entry("atlas-personal-dev", "git config --get user.email").strip() == "george@lydakis.me"
        assert entry("atlas-restricted", "id -u").strip() == "1000"
        assert entry("atlas-restricted", "pwd").strip() == "/home/owner"
        entry("atlas-restricted", "touch resettable-owner-home")
        assert entry("atlas-restricted", "sudo -n id -u").strip() == "0"
        entry("atlas-restricted", "command -v git", succeeds=False)
        assert entry("atlas-shared-dev", "sudo -n id -u").strip() == "0"
        entry("atlas-shared-dev", "test ! -S /var/lib/incus/unix.socket")
        entry("atlas-shared-dev", "test ! -S /run/incus/unix.socket")
        entry("atlas-shared-dev", "test ! -S /dev/incus/sock")

    with subtest("control identity is bound to the environment listener"):
        leader = machine.succeed(
            "incus info atlas-shared-dev | sed -n 's/^PID: //p'"
        ).strip()
        host_cgroup = machine.succeed(f"cat /proc/{leader}/cgroup").strip()
        machine.log(f"Incus entry host cgroup: {host_cgroup}")
        assert "lxc.payload.atlas-shared-dev" in host_cgroup
        inspected = json.loads(entry("atlas-shared-dev", "atlas environment inspect self --json"))
        assert inspected["ok"] is True
        assert inspected["result"]["name"] == "shared-dev"

    with subtest("ordinary mutable root and durable data persist independently"):
        entry("atlas-shared-dev", "sudo -n sh -c 'echo root > /etc/atlas-root-state'")
        entry("atlas-shared-dev", "mkdir -p Documents .config/atlas Projects/repo-a")
        entry("atlas-shared-dev", "echo durable > Documents/owner-state")
        entry("atlas-shared-dev", "echo resettable > .config/atlas/config-state")
        entry("atlas-shared-dev", "echo volume > Projects/repo-a/volume-state")
        machine.succeed("incus restart --timeout 30 --force atlas-shared-dev")
        wait_for_instance("atlas-shared-dev")
        entry("atlas-shared-dev", "test -f /etc/atlas-root-state")
        assert entry("atlas-personal-dev", "cat Documents/owner-state").strip() == "durable"
        assert entry("atlas-personal-dev", "cat Projects/repo-a/volume-state").strip() == "volume"
        entry("atlas-restricted", "test -e /home/owner/Documents/owner-state", succeeds=False)

    with subtest("Ubuntu package installation mutates only one instance root"):
        machine.succeed(
            "incus file push ${testPackage} atlas-shared-dev/tmp/atlas-proof-tool.deb"
        )
        entry("atlas-shared-dev", "sudo -n dpkg -i /tmp/atlas-proof-tool.deb")
        assert entry("atlas-shared-dev", "atlas-proof-tool").strip() == "atlas-proof-tool-installed"
        entry("atlas-personal-dev", "command -v atlas-proof-tool", succeeds=False)

    with subtest("snapshot restore rolls back root and resettable home only"):
        project_path = environment_entry["environments"]["shared-dev"]["volumes"][0]["hostPath"]
        expected_layout = environment_entry["environments"]["shared-dev"]["runtime"]["layoutId"]
        project_inode_before = machine.succeed(
            f"stat -c '%d:%i' {shlex.quote(project_path)}"
        ).strip()
        machine.succeed("incus config set atlas-shared-dev security.nesting=true")
        machine.succeed("incus snapshot create atlas-shared-dev stale-layout")
        machine.succeed("incus config unset atlas-shared-dev security.nesting")
        machine.fail(
            "atlas environment snapshot restore shared-dev stale-layout --json"
        )
        assert machine.succeed(
            "incus config get atlas-shared-dev user.atlas.layout-id"
        ).strip() == expected_layout
        machine.succeed("atlas environment snapshot delete shared-dev stale-layout --json")
        machine.succeed("atlas environment snapshot create shared-dev baseline --json")
        entry("atlas-shared-dev", "sudo -n touch /etc/after-snapshot")
        entry("atlas-shared-dev", "echo later > .config/atlas/after-snapshot")
        entry("atlas-shared-dev", "echo durable-later > Documents/after-snapshot")
        entry("atlas-shared-dev", "echo volume-later > Projects/repo-a/after-snapshot")
        machine.succeed("atlas environment snapshot restore shared-dev baseline --json")
        wait_for_instance("atlas-shared-dev")
        project_inode_after = machine.succeed(
            f"stat -c '%d:%i' {shlex.quote(project_path)}"
        ).strip()
        assert project_inode_after == project_inode_before
        entry("atlas-shared-dev", "test ! -e /etc/after-snapshot")
        entry("atlas-shared-dev", "test ! -e .config/atlas/after-snapshot")
        assert entry("atlas-shared-dev", "cat Documents/after-snapshot").strip() == "durable-later"
        assert entry("atlas-shared-dev", "cat Projects/repo-a/after-snapshot").strip() == "volume-later"
        snapshots = json.loads(machine.succeed("atlas environment snapshot list shared-dev --json"))
        assert snapshots["result"]["snapshots"] == ["baseline"]
        machine.fail("atlas environment reset shared-dev --json")
        snapshots = json.loads(machine.succeed("atlas environment snapshot list shared-dev --json"))
        assert snapshots["result"]["snapshots"] == ["baseline"]
        machine.succeed("atlas environment snapshot delete shared-dev baseline --json")

    with subtest("explicit reset recreates root and dependent volumes"):
        owner_home_path = environment_entry["owner"]["homeStorage"]["hostPath"]
        inode_before = machine.succeed(f"stat -c '%d:%i' {shlex.quote(owner_home_path)}").strip()
        machine.succeed("atlas environment reset shared-dev --json")
        wait_for_instance("atlas-shared-dev")
        inode_after = machine.succeed(f"stat -c '%d:%i' {shlex.quote(owner_home_path)}").strip()
        assert inode_after == inode_before
        entry("atlas-shared-dev", "test ! -e /etc/atlas-root-state")
        entry("atlas-shared-dev", "command -v atlas-proof-tool", succeeds=False)
        entry("atlas-shared-dev", "test ! -e .config/atlas/config-state")
        assert entry("atlas-shared-dev", "cat Documents/owner-state").strip() == "durable"
        assert entry("atlas-shared-dev", "cat Projects/repo-a/volume-state").strip() == "volume"

    with subtest("private network namespaces and ACL are applied"):
        shared_pid = machine.succeed("incus info atlas-shared-dev | sed -n 's/^PID: //p'").strip()
        personal_pid = machine.succeed("incus info atlas-personal-dev | sed -n 's/^PID: //p'").strip()
        assert shared_pid != personal_pid
        shared_net = machine.succeed(f"readlink /proc/{shared_pid}/ns/net").strip()
        personal_net = machine.succeed(f"readlink /proc/{personal_pid}/ns/net").strip()
        assert shared_net != personal_net
        for name in ("atlas-shared-dev", "atlas-personal-dev", "atlas-restricted"):
            assert machine.succeed(
                f"incus config device get {name} eth0 security.acls"
            ).strip() == "atlas-private"

        machine.succeed(
            "incus network acl rule add atlas-private egress "
            "action=allow destination=203.0.113.0/24"
        )
        machine.succeed("systemctl restart atlas-incus-network-policy.service")
        machine.fail(
            "incus network acl show atlas-private "
            "| grep -F 203.0.113.0/24"
        )

        machine.succeed("ip link add atlasprobe type dummy")
        machine.succeed("ip addr add 203.0.113.10/32 dev atlasprobe")
        machine.succeed("ip link set atlasprobe up")
        machine.succeed(
            "systemd-run --unit atlas-network-probe --service-type=exec "
            "systemd-socket-activate -l 0.0.0.0:19090 /bin/cat"
        )
        machine.wait_until_succeeds("ss -ltn | grep -F ':19090'", timeout=30)
        entry(
            "atlas-shared-dev",
            "timeout 2 bash -c 'exec 3<>/dev/tcp/203.0.113.10/19090'",
            succeeds=False,
        )

    with subtest("system reconciliation shares the lifecycle lock"):
        service = "atlas-environment-shared\\x2ddev.service"
        environment_id = environment_entry["environments"]["shared-dev"]["id"]
        lock = f"/run/atlas/locks/{environment_id}.lock"
        machine.succeed(
            f"nohup flock {shlex.quote(lock)} -c 'sleep 10' >/dev/null 2>&1 &"
        )
        machine.wait_until_succeeds(
            f"! flock -n {shlex.quote(lock)} -c true", timeout=5
        )
        machine.succeed(f"systemctl restart --no-block '{service}'")
        machine.succeed("sleep 5")
        machine.succeed(
            "systemctl list-jobs --no-legend "
            "| grep -F 'atlas-environment-shared\\x2ddev.service'"
        )
        machine.fail(f"flock -n {shlex.quote(lock)} -c true")
        machine.wait_until_succeeds(
            f"flock -n {shlex.quote(lock)} -c true", timeout=15
        )
        machine.wait_until_succeeds(
            "! systemctl list-jobs --no-legend "
            "| grep -F 'atlas-environment-shared\\x2ddev.service'",
            timeout=60,
        )
        machine.succeed(f"systemctl is-active '{service}'")

    with subtest("reconciliation rejects missing environment identity"):
        service = "atlas-environment-shared\\x2ddev.service"
        environment_id = environment_entry["environments"]["shared-dev"]["id"]
        machine.succeed(
            "incus config unset atlas-shared-dev user.atlas.environment-id"
        )
        machine.fail(f"systemctl restart '{service}'")
        assert machine.succeed(
            "incus list '^atlas-shared-dev$' --format csv -c s"
        ).strip() == "STOPPED"
        assert machine.succeed(
            "incus config get atlas-shared-dev boot.autostart"
        ).strip() == "false"
        machine.succeed(
            "incus config set atlas-shared-dev user.atlas.environment-id "
            f"{shlex.quote(environment_id)}"
        )
        machine.succeed(f"systemctl restart '{service}'")
        wait_for_instance("atlas-shared-dev")

    with subtest("reconciliation rejects inherited profile devices"):
        service = "atlas-environment-shared\\x2ddev.service"
        machine.succeed("incus profile create atlas-unexpected")
        machine.succeed(
            "incus profile device add atlas-unexpected inherited-device none"
        )
        machine.succeed("incus profile add atlas-shared-dev atlas-unexpected")
        machine.fail(f"systemctl restart '{service}'")
        assert machine.succeed(
            "incus list '^atlas-shared-dev$' --format csv -c s"
        ).strip() == "STOPPED"
        assert machine.succeed(
            "incus config get atlas-shared-dev boot.autostart"
        ).strip() == "false"
        machine.succeed("incus profile remove atlas-shared-dev atlas-unexpected")
        machine.succeed(f"systemctl restart '{service}'")
        wait_for_instance("atlas-shared-dev")
        machine.succeed("incus profile delete atlas-unexpected")

    with subtest("mutable default profile cannot change Atlas instances"):
        service = "atlas-environment-shared\\x2ddev.service"
        machine.succeed("incus profile set default security.nesting=true")
        machine.succeed(f"systemctl restart '{service}'")
        wait_for_instance("atlas-shared-dev")
        assert "security.nesting" not in json.loads(machine.succeed(
            "incus query /1.0/instances/atlas-shared-dev"
        ))["expanded_config"]
        machine.succeed("incus profile unset default security.nesting")

    with subtest("stable guest contract directory follows atomic updates"):
        assert machine.succeed(
            "incus config device get atlas-shared-dev atlas-contract source"
        ).strip() == "/run/atlas/guest-contract"
        host_contract_hash = machine.succeed(
            "sha256sum /etc/atlas/control-contract.json | cut -d' ' -f1"
        ).strip()
        assert entry(
            "atlas-shared-dev",
            "sha256sum /etc/atlas-host/control-contract.json | cut -d' ' -f1",
        ).strip() == host_contract_hash
        machine.succeed(
            "printf '%s\\n' '{\"generation\":\"replacement\"}' "
            "> /run/atlas/guest-contract/.next-contract"
        )
        machine.succeed(
            "mv /run/atlas/guest-contract/.next-contract "
            "/run/atlas/guest-contract/control-contract.json"
        )
        assert json.loads(
            entry("atlas-shared-dev", "cat /etc/atlas-host/control-contract.json")
        ) == {"generation": "replacement"}
        machine.succeed(
            "install -m 0644 /etc/atlas/control-contract.json "
            "/run/atlas/guest-contract/.next-contract"
        )
        machine.succeed(
            "mv /run/atlas/guest-contract/.next-contract "
            "/run/atlas/guest-contract/control-contract.json"
        )
        assert entry(
            "atlas-shared-dev",
            "sha256sum /etc/atlas-host/control-contract.json | cut -d' ' -f1",
        ).strip() == host_contract_hash

    with subtest("instance drift fails closed and incomplete creation self-recovers"):
        service = "atlas-environment-shared\\x2ddev.service"
        machine.succeed("incus config device remove atlas-shared-dev nix-store")
        machine.fail(f"systemctl restart '{service}'")
        machine.succeed("atlas environment reset shared-dev --json")
        machine.succeed(f"systemctl reset-failed '{service}'")
        machine.succeed(f"systemctl restart '{service}'")
        entry("atlas-shared-dev", "sudo -n touch /etc/incomplete-atlas-instance")
        machine.succeed(
            "incus config unset atlas-shared-dev user.atlas.layout-id"
        )
        machine.succeed(f"systemctl restart '{service}'")
        entry("atlas-shared-dev", "test ! -e /etc/incomplete-atlas-instance")

    with subtest("Incus daemon restart preserves live environments"):
        pid_before = machine.succeed("incus info atlas-shared-dev | sed -n 's/^PID: //p'").strip()
        machine.succeed("timeout 60 systemctl restart incus.service")
        machine.succeed("incus admin waitready")
        pid_after = machine.succeed("incus info atlas-shared-dev | sed -n 's/^PID: //p'").strip()
        assert pid_after == pid_before
        entry("atlas-shared-dev", "test -f Documents/owner-state")

    with subtest("inventory quarantines removed Atlas environments"):
        machine.succeed(
            "image=$(incus image list --format csv -c l | head -n1); "
            "incus init \"$image\" atlas-orphan "
            "--config user.atlas.environment-id=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa "
            "--config boot.autostart=true"
        )
        machine.succeed("incus start atlas-orphan")
        machine.succeed("systemctl restart atlas-incus-inventory.service")
        assert machine.succeed(
            "incus list '^atlas-orphan$' --format csv -c s"
        ).strip() == "STOPPED"
        assert machine.succeed(
            "incus config get atlas-orphan boot.autostart"
        ).strip() == "false"
  '';
}
