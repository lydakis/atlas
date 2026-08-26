{ pkgs, atlasModule }:
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

    start_all()

    machine.wait_for_unit("atlas-host.target")
    machine.wait_for_unit("tailscaled.service")
    machine.wait_for_unit("atlas-spike-alpha.service")
    machine.wait_for_unit("atlas-spike-beta.service")

    contract = json.loads(machine.succeed("cat /etc/atlas/host-contract.json"))
    assert contract["version"] == 3
    assert contract["intent"]["primitives"] == ["host", "environment", "grant", "surface", "route"]
    assert contract["implementation"]["primitives"] == ["host"]
    assert contract["state"]["root"] == "/var/lib/atlas"
    assert contract["state"]["rootMode"] == "0711"
    assert contract["configuration"]["connectivity"]["openSshConfigured"] is False
    assert contract["configuration"]["connectivity"]["tailscale"]["adapterEnabled"] is True
    assert contract["configuration"]["connectivity"]["tailscale"]["sshRequested"] is True
    assert contract["configuration"]["connectivity"]["tailscale"]["enrollmentMode"] == "interactive"
    assert contract["configuration"]["nix"]["allowedUsers"] == ["root"]
    assert contract["configuration"]["nix"]["trustedUsers"] == ["root"]

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
    machine.succeed("systemctl show atlas-spike-alpha.service -p Slice --value | grep -Fx atlas-environments.slice")
    machine.succeed("systemctl show atlas-spike-beta.service -p Slice --value | grep -Fx atlas-environments.slice")

    alpha_pid = machine.succeed("systemctl show atlas-spike-alpha.service -p MainPID --value").strip()
    beta_pid = machine.succeed("systemctl show atlas-spike-beta.service -p MainPID --value").strip()
    alpha_uid = machine.succeed(f"awk '/^Uid:/ {{ print $2 }}' /proc/{alpha_pid}/status").strip()
    alpha_gid = machine.succeed(f"awk '/^Gid:/ {{ print $2 }}' /proc/{alpha_pid}/status").strip()
    alpha_netns = machine.succeed(f"readlink /proc/{alpha_pid}/ns/net").strip()
    beta_netns = machine.succeed(f"readlink /proc/{beta_pid}/ns/net").strip()
    assert alpha_netns != beta_netns

    machine.succeed(f"nsenter --net=/proc/{alpha_pid}/ns/net curl -fsS http://127.0.0.1:3000 | grep -F 'atlas environment alpha'")
    machine.succeed(f"nsenter --net=/proc/{beta_pid}/ns/net curl -fsS http://127.0.0.1:3000 | grep -F 'atlas environment beta'")

    allowed_users = machine.succeed("nix config show --json | jq -r '.\"allowed-users\".value | join(\" \")'").strip()
    trusted_users = machine.succeed("nix config show --json | jq -r '.\"trusted-users\".value | join(\" \")'").strip()
    assert allowed_users == "root"
    assert trusted_users == "root"

    sentinel = "environment-state-owned-before-restart"
    machine.succeed(
        f"nsenter --mount=/proc/{alpha_pid}/ns/mnt --setuid={alpha_uid} --setgid={alpha_gid} "
        f"sh -c 'echo {sentinel} > /var/lib/atlas/environments/spike-alpha/generation-probe'"
    )

    def assert_alpha_state():
        pid = machine.succeed("systemctl show atlas-spike-alpha.service -p MainPID --value").strip()
        machine.succeed(
            f"nsenter --mount=/proc/{pid}/ns/mnt "
            f"grep -Fx {sentinel} /var/lib/atlas/environments/spike-alpha/generation-probe"
        )

    assert_alpha_state()
    machine.succeed("systemctl restart atlas-spike-alpha.service")
    machine.wait_for_unit("atlas-spike-alpha.service")
    assert_alpha_state()
    baseline = machine.succeed("readlink -f /run/current-system").strip()
    updated = machine.succeed("readlink -f /run/current-system/specialisation/atlas-updated").strip()

    machine.succeed(f"{updated}/bin/switch-to-configuration test")
    machine.succeed("grep -Fx updated /etc/atlas-spike-generation")
    assert_alpha_state()

    machine.succeed(f"{baseline}/bin/switch-to-configuration test")
    machine.succeed("grep -Fx baseline /etc/atlas-spike-generation")
    assert_alpha_state()
  '';
}
