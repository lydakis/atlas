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
    machine.wait_for_unit("atlas-spike-alpha.service")
    machine.wait_for_unit("atlas-spike-beta.service")

    contract = json.loads(machine.succeed("cat /etc/atlas/host-contract.json"))
    assert contract["version"] == 1
    assert contract["dataRoot"] == "/var/lib/atlas"
    assert contract["nixAllowedUsers"] == ["root"]
    assert contract["nixTrustedUsers"] == ["root"]
    assert contract["remoteOperatorEnabled"] is False

    machine.succeed("test $(stat -c %a /var/lib/atlas/credentials) = 700")
    machine.succeed("test $(stat -c %U /var/lib/atlas/credentials) = atlas-control")
    machine.succeed("test $(stat -c %G /var/lib/atlas/credentials) = atlas-control")
    machine.succeed("systemctl show atlas-host-contract.service -p Slice --value | grep -Fx atlas-control.slice")
    machine.succeed("systemctl show atlas-spike-alpha.service -p Slice --value | grep -Fx atlas-workloads.slice")
    machine.succeed("systemctl show atlas-spike-beta.service -p Slice --value | grep -Fx atlas-workloads.slice")

    alpha_pid = machine.succeed("systemctl show atlas-spike-alpha.service -p MainPID --value").strip()
    beta_pid = machine.succeed("systemctl show atlas-spike-beta.service -p MainPID --value").strip()
    alpha_netns = machine.succeed(f"readlink /proc/{alpha_pid}/ns/net").strip()
    beta_netns = machine.succeed(f"readlink /proc/{beta_pid}/ns/net").strip()
    assert alpha_netns != beta_netns

    machine.succeed(f"nsenter --net=/proc/{alpha_pid}/ns/net curl -fsS http://127.0.0.1:3000 | grep -F 'atlas workload alpha'")
    machine.succeed(f"nsenter --net=/proc/{beta_pid}/ns/net curl -fsS http://127.0.0.1:3000 | grep -F 'atlas workload beta'")

    allowed_users = machine.succeed("nix config show --json | jq -r '.\"allowed-users\".value | join(\" \")'").strip()
    trusted_users = machine.succeed("nix config show --json | jq -r '.\"trusted-users\".value | join(\" \")'").strip()
    assert allowed_users == "root"
    assert trusted_users == "root"

    machine.succeed("echo durable-state > /var/lib/atlas/workspaces/generation-probe")
    baseline = machine.succeed("readlink -f /run/current-system").strip()
    updated = machine.succeed("readlink -f /run/current-system/specialisation/atlas-updated").strip()

    machine.succeed(f"{updated}/bin/switch-to-configuration test")
    machine.succeed("grep -Fx updated /etc/atlas-spike-generation")
    machine.succeed("grep -Fx durable-state /var/lib/atlas/workspaces/generation-probe")

    machine.succeed(f"{baseline}/bin/switch-to-configuration test")
    machine.succeed("grep -Fx baseline /etc/atlas-spike-generation")
    machine.succeed("grep -Fx durable-state /var/lib/atlas/workspaces/generation-probe")
  '';
}
