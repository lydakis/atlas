{ pkgs }:
let
  ubuntuImageMetadata = pkgs.fetchurl {
    url = "https://images.linuxcontainers.org/images/ubuntu/noble/amd64/default/20260829_07:42/incus.tar.xz";
    sha256 = "660cee023a16d9a4b275297137de4952ce390af8e2a032a5c1f9948bc7a5a3d9";
  };
  ubuntuImageRoot = pkgs.fetchurl {
    url = "https://images.linuxcontainers.org/images/ubuntu/noble/amd64/default/20260829_07:42/rootfs.squashfs";
    sha256 = "493195662fccde5edaf5a2ddd05b7aaf01cc88cf4a79d0504637c80c3bf3f620";
  };
  testPackage =
    pkgs.runCommand "atlas-incus-proof-tool_1.0_all.deb"
      {
        nativeBuildInputs = [ pkgs.dpkg ];
      }
      ''
        mkdir -p package/DEBIAN package/usr/local/bin
        cat > package/DEBIAN/control <<'EOF'
        Package: atlas-incus-proof-tool
        Version: 1.0
        Architecture: all
        Maintainer: Atlas Test <atlas@example.invalid>
        Description: Offline package-manager fixture for the Incus substrate proof
        EOF
        cat > package/usr/local/bin/atlas-incus-proof-tool <<'EOF'
        #!/bin/sh
        echo atlas-incus-proof-tool-installed
        EOF
        chmod 0755 package/usr/local/bin/atlas-incus-proof-tool
        dpkg-deb --root-owner-group --build package "$out"
      '';
in
pkgs.testers.runNixOSTest {
  name = "atlas-incus-substrate";

  requiredFeatures.kvm = false;
  qemu.forceAccel = false;

  nodes.machine = {
    imports = [ ../configurations/btrfs-vm-storage.nix ];

    networking = {
      nftables.enable = true;
      firewall.trustedInterfaces = [ "atlasbr0" ];
      dhcpcd.denyInterfaces = [
        "atlasbr0"
        "veth*"
      ];
    };
    environment.systemPackages = [ pkgs.python3 ];
    security.apparmor.enable = true;
    systemd.tmpfiles.rules = [
      "d /var/lib/incus/security/apparmor/profiles 0700 root root -"
    ];

    virtualisation = {
      cores = 2;
      memorySize = 4096;
      incus = {
        enable = true;
        package = pkgs.incus-lts;
        preseed = {
          storage_pools = [
            {
              name = "atlas";
              driver = "btrfs";
              config.source = "/var/lib/atlas/incus-pool";
            }
          ];
          networks = [
            {
              name = "atlasbr0";
              type = "bridge";
              config = {
                "ipv4.address" = "10.211.0.1/24";
                "ipv4.nat" = "true";
                "ipv6.address" = "none";
              };
            }
          ];
          profiles = [
            {
              name = "default";
              description = "Atlas Incus substrate proof";
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
    };
  };

  testScript = ''
    import shlex
    import time

    serial_stdout_off()
    machine.start(allow_reboot=True)
    machine.wait_for_unit("incus.service")
    machine.wait_for_unit("incus-preseed.service")
    machine.succeed("incus admin waitready")

    def instance_exec(name, command, succeeds=True):
        invocation = (
            f"timeout -k 5 30 incus exec {name} -T -n -- "
            f"bash -lc {shlex.quote(command)}"
        )
        if succeeds:
            return machine.succeed(invocation)
        return machine.fail(invocation)

    def wait_for_instance(name, address):
        diagnostics = (
            f"incus info --show-log {name}; "
            f"timeout -k 5 10 incus exec {name} -T -n -- "
            "networkctl status eth0 --no-pager || true; "
            f"timeout -k 5 10 incus exec {name} -T -n -- "
            "journalctl -u systemd-networkd "
            "--no-pager -n 100 || true; "
            f"timeout -k 5 10 incus --debug exec {name} -T -n -- true || true; "
            "incus operation list || true; "
            "journalctl -u incus.service --no-pager -n 200 || true; "
            "ip -d link show atlasbr0 || true; "
            "nft list ruleset || true; "
            "incus network list-leases atlasbr0 || true; "
            "cat /var/lib/incus/networks/atlasbr0/dnsmasq.leases || true"
        )
        try:
            machine.wait_until_succeeds(
                f"incus list {name} --format csv -c 4 | grep -F "
                f"{shlex.quote(address)}",
                timeout=120,
            )
            machine.succeed(
                f"timeout -k 5 15 incus exec {name} -T -n -- true"
            )
        except Exception:
            diagnostic_status, diagnostic_output = machine.execute(diagnostics)
            machine.log(
                f"Incus diagnostics exited {diagnostic_status}:\n"
                f"{diagnostic_output}"
            )
            raise

    def create_instance(name, address):
        machine.succeed(
            f"incus init atlas-ubuntu {name} "
            "--config security.idmap.isolated=true "
            "--config security.guestapi=false "
            "--config linux.sysctl.net.ipv6.conf.all.disable_ipv6=1 "
            "--config linux.sysctl.net.ipv6.conf.default.disable_ipv6=1 "
            "--config boot.autostart=true "
            "--config boot.host_shutdown_action=force-stop"
        )
        machine.succeed(
            f"incus config device override {name} eth0 "
            f"ipv4.address={address}"
        )
        machine.succeed(
            f"incus config device add {name} owner-home disk "
            "pool=atlas source=owner-home path=/home/ubuntu"
        )
        machine.succeed(
            f"incus storage volume create atlas {name}-config "
            "initial.uid=1000 initial.gid=1000 initial.mode=0700 "
            "security.shifted=true"
        )
        machine.succeed(
            f"incus config device add {name} resettable-config disk "
            f"pool=atlas source={name}-config path=/home/ubuntu/.config "
            "dependent=true"
        )
        machine.succeed(
            f"incus start {name} || "
            f"(incus info --show-log {name}; exit 1)"
        )
        wait_for_instance(name, address)

    with subtest("pinned NixOS Incus module and Btrfs pool initialize"):
        version = machine.succeed("incus version")
        assert "7.0.1" in version
        machine.succeed("grep -Fx Y /sys/module/apparmor/parameters/enabled")
        machine.succeed("systemctl is-active apparmor.service")
        storage = machine.succeed("incus storage show atlas")
        assert "driver: btrfs" in storage
        assert "source: /var/lib/atlas/incus-pool" in storage
        machine.succeed("findmnt -n -o FSTYPE /var/lib/atlas | grep -Fx btrfs")
        machine.succeed("test -S /var/lib/incus/unix.socket")
        machine.succeed("test $(stat -c %a /var/lib/incus/unix.socket) = 660")
        machine.succeed("test $(stat -c %G /var/lib/incus/unix.socket) = incus-admin")

    with subtest("pinned Ubuntu system image imports without network access"):
        machine.succeed(
            "incus image import "
            "${ubuntuImageMetadata} ${ubuntuImageRoot} --alias atlas-ubuntu"
        )
        machine.succeed("incus image info atlas-ubuntu")
        machine.succeed("incus image alias list | grep -F atlas-ubuntu")

    with subtest("isolated instances share one shifted durable volume"):
        machine.succeed(
            "incus storage volume create atlas owner-home "
            "initial.uid=1000 initial.gid=1000 initial.mode=0700 "
            "security.shifted=true"
        )
        machine.succeed(
            "incus storage volume file create atlas owner-home/.config "
            "--type=directory --uid=1000 --gid=1000 --mode=0700"
        )
        create_instance("env-a", "10.211.0.11")
        create_instance("env-b", "10.211.0.12")
        for name in ("env-a", "env-b"):
            assert machine.succeed(
                f"incus config get {name} security.idmap.isolated"
            ).strip() == "true"
            instance_exec(name, "test -x /usr/bin/apt")
            instance_exec(name, "test ! -S /var/lib/incus/unix.socket")
            instance_exec(name, "test ! -S /run/incus/unix.socket")
            instance_exec(name, "test ! -S /dev/incus/sock")
            instance_exec(name, "test ! -s /proc/net/if_inet6")
        map_a = machine.succeed("incus config get env-a volatile.idmap.current").strip()
        map_b = machine.succeed("incus config get env-b volatile.idmap.current").strip()
        assert map_a and map_b and map_a != map_b
        instance_exec(
            "env-a",
            "runuser -u ubuntu -- sh -c 'printf durable > /home/ubuntu/work.txt'",
        )
        assert instance_exec("env-b", "cat /home/ubuntu/work.txt").strip() == "durable"
        instance_exec(
            "env-a",
            "runuser -u ubuntu -- sh -c 'printf local > /home/ubuntu/.config/local'",
        )
        instance_exec("env-b", "test ! -e /home/ubuntu/.config/local")

    with subtest("Ubuntu root is mutable and persists across instance restart"):
        machine.succeed(
            "incus file push ${testPackage} "
            "env-a/tmp/atlas-incus-proof-tool.deb"
        )
        instance_exec("env-a", "dpkg -i /tmp/atlas-incus-proof-tool.deb")
        assert instance_exec("env-a", "atlas-incus-proof-tool").strip() == (
            "atlas-incus-proof-tool-installed"
        )
        instance_exec("env-a", "printf root-drift > /etc/atlas-root-drift")
        machine.succeed("incus restart --timeout 15 --force env-a")
        wait_for_instance("env-a", "10.211.0.11")
        instance_exec("env-a", "test -f /etc/atlas-root-drift")
        instance_exec("env-a", "atlas-incus-proof-tool")

    with subtest("root snapshot restore excludes later durable-volume writes"):
        machine.succeed("incus stop --timeout 15 --force env-a")
        machine.succeed("incus snapshot create env-a before-later-drift")
        machine.succeed("incus start env-a")
        wait_for_instance("env-a", "10.211.0.11")
        instance_exec("env-a", "printf later-root > /etc/atlas-later-root")
        instance_exec(
            "env-a",
            "runuser -u ubuntu -- sh -c 'printf later > /home/ubuntu/.config/later'",
        )
        instance_exec(
            "env-a",
            "runuser -u ubuntu -- sh -c 'printf later-durable >> /home/ubuntu/work.txt'",
        )
        machine.succeed("incus stop --timeout 15 --force env-a")
        machine.succeed("incus snapshot restore env-a before-later-drift")
        machine.succeed("incus start env-a")
        wait_for_instance("env-a", "10.211.0.11")
        instance_exec("env-a", "test ! -e /etc/atlas-later-root")
        instance_exec("env-a", "test ! -e /home/ubuntu/.config/later")
        assert instance_exec("env-a", "cat /home/ubuntu/.config/local").strip() == (
            "local"
        )
        assert instance_exec("env-a", "cat /home/ubuntu/work.txt").strip() == (
            "durablelater-durable"
        )

    with subtest("recreation resets root while preserving the durable volume"):
        reset_started = time.monotonic()
        machine.succeed("incus delete --force env-a")
        machine.fail("incus storage volume show atlas env-a-config")
        create_instance("env-a", "10.211.0.11")
        reset_seconds = time.monotonic() - reset_started
        machine.log(f"Incus recreation reset completed in {reset_seconds:.3f}s")
        instance_exec("env-a", "test ! -e /etc/atlas-root-drift")
        instance_exec("env-a", "test ! -x /usr/local/bin/atlas-incus-proof-tool")
        instance_exec("env-a", "test ! -e /home/ubuntu/.config/local")
        assert instance_exec("env-a", "cat /home/ubuntu/work.txt").strip() == (
            "durablelater-durable"
        )

    with subtest("daemon restart leaves running instances alive"):
        pid_before = machine.succeed("incus info env-a | sed -n 's/^PID: //p'").strip()
        machine.succeed(f"test -n {shlex.quote(pid_before)}")
        machine.succeed(f"test -d /proc/{pid_before}")
        machine.succeed("timeout 60 systemctl restart incus.service")
        machine.succeed("incus admin waitready")
        pid_after = machine.succeed("incus info env-a | sed -n 's/^PID: //p'").strip()
        assert pid_after == pid_before
        machine.succeed(f"test -d /proc/{pid_after}")
        instance_exec("env-a", "test -f /home/ubuntu/work.txt")

    with subtest("instances have independent loopback and network namespaces"):
        pids = {
            name: machine.succeed(f"incus info {name} | sed -n 's/^PID: //p'").strip()
            for name in ("env-a", "env-b")
        }
        netns = {
            name: machine.succeed(f"readlink /proc/{pid}/ns/net").strip()
            for name, pid in pids.items()
        }
        assert netns["env-a"] != netns["env-b"]
        for name in ("env-a", "env-b"):
            instance_exec(
                name,
                "systemd-run --unit atlas-loopback --service-type=exec "
                "systemd-socket-activate -l 127.0.0.1:18080 /bin/cat",
            )
            instance_exec(name, "ss -ltn | grep -F '127.0.0.1:18080'")

    with subtest("default bridge permits cross-environment traffic"):
        instance_exec(
            "env-b",
            "systemd-run --unit atlas-cross-environment --service-type=exec "
            "systemd-socket-activate -l 0.0.0.0:18081 /bin/cat",
        )
        env_b_ip = machine.succeed(
            "incus list env-b --format csv -c 4 | cut -d' ' -f1"
        ).strip()
        machine.succeed(f"test -n {shlex.quote(env_b_ip)}")
        instance_exec("env-a", f"timeout 2 bash -c 'echo probe >/dev/tcp/{env_b_ip}/18081'")

    with subtest("NIC ACL blocks cross-environment and private destinations"):
        machine.succeed("incus network acl create atlas-private")
        machine.succeed(
            "incus network acl rule add atlas-private egress "
            "action=allow destination=10.211.0.1 protocol=udp destination_port=53"
        )
        machine.succeed(
            "incus network acl rule add atlas-private egress "
            "action=allow destination=10.211.0.1 protocol=tcp destination_port=53"
        )
        for destination in (
            "10.0.0.0/8",
            "100.64.0.0/10",
            "169.254.0.0/16",
            "172.16.0.0/12",
            "192.168.0.0/16",
        ):
            machine.succeed(
                "incus network acl rule add atlas-private egress "
                f"action=reject destination={destination}"
            )
        machine.succeed(
            "incus network acl rule add atlas-private egress action=allow"
        )
        for name in ("env-a", "env-b"):
            machine.succeed(
                f"incus config device set {name} eth0 "
                "security.acls=atlas-private"
            )
        instance_exec(
            "env-a",
            f"timeout 2 bash -c 'echo blocked >/dev/tcp/{env_b_ip}/18081'",
            succeeds=False,
        )

        machine.succeed("ip link add atlasprobe type dummy")
        machine.succeed("ip addr add 192.168.50.10/32 dev atlasprobe")
        machine.succeed("ip addr add 100.100.100.10/32 dev atlasprobe")
        machine.succeed("ip addr add 169.254.169.254/32 dev atlasprobe")
        machine.succeed("ip addr add 203.0.113.10/32 dev atlasprobe")
        machine.succeed("ip link set atlasprobe up")
        machine.succeed(
            "systemd-run --unit atlas-network-probe --service-type=exec "
            "python3 -m http.server 19090 --bind 0.0.0.0"
        )
        machine.wait_until_succeeds("ss -ltn | grep -F ':19090'", timeout=30)
        instance_exec(
            "env-a",
            "timeout 2 bash -c 'exec 3<>/dev/tcp/203.0.113.10/19090'",
        )
        for address in (
            "10.211.0.1",
            "192.168.50.10",
            "100.100.100.10",
            "169.254.169.254",
        ):
            instance_exec(
                "env-a",
                f"timeout 2 bash -c 'exec 3<>/dev/tcp/{address}/19090'",
                succeeds=False,
            )

    with subtest("host reboot autostarts instances and preserves persistent state"):
        boot_id_before = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
        instance_exec("env-a", "printf reboot-root > /etc/atlas-reboot-root")
        instance_exec(
            "env-a",
            "runuser -u ubuntu -- sh -c "
            "'printf reboot-local > /home/ubuntu/.config/reboot-local'",
        )
        instance_exec(
            "env-a",
            "runuser -u ubuntu -- sh -c "
            "'printf reboot-durable > /home/ubuntu/reboot-durable'",
        )
        machine.reboot()
        machine.wait_for_unit("incus.service")
        machine.wait_for_unit("incus-preseed.service")
        machine.succeed("incus admin waitready")
        wait_for_instance("env-a", "10.211.0.11")
        wait_for_instance("env-b", "10.211.0.12")
        boot_id_after = machine.succeed("cat /proc/sys/kernel/random/boot_id").strip()
        assert boot_id_after != boot_id_before
        instance_exec("env-a", "test -f /etc/atlas-reboot-root")
        instance_exec("env-a", "test -f /home/ubuntu/.config/reboot-local")
        instance_exec("env-a", "test -f /home/ubuntu/reboot-durable")
        instance_exec("env-b", "test -f /home/ubuntu/reboot-durable")
        for name in ("env-a", "env-b"):
            instance_exec(name, "! ss -ltn | grep -Eq ':18080|:18081'")

    with subtest("instances stop without deleting persistent state"):
        machine.succeed("incus stop --force env-a env-b")
        machine.succeed("incus storage show atlas | grep -F 'driver: btrfs'")
        machine.succeed("incus storage volume show atlas owner-home")
  '';
}
