"""Runtime network proof, loaded by host-contract.nix in the NixOS test driver."""

private_probes = ("10.50.0.10", "100.100.100.10", "169.254.169.254", "172.20.0.10", "192.168.50.10")


def setup_network_probes():
    # These fixtures are recreated after reboot, not after a generation switch.
    machine.succeed("ip link add atlasprobe type dummy")
    machine.succeed("ip addr add 198.51.100.10/32 dev atlasprobe")
    machine.succeed("ip link set atlasprobe up")
    machine.succeed(
        "systemd-run --unit atlas-host-probe --service-type=exec "
        f"{probe_python} -m http.server 19090 --bind 0.0.0.0"
    )
    machine.succeed("ip netns add atlas-external")
    machine.succeed("ip link add atlaswan type veth peer name atlaspeer")
    machine.succeed("ip link set atlaspeer netns atlas-external")
    machine.succeed("ip addr add 203.0.113.1/24 dev atlaswan")
    machine.succeed("ip link set atlaswan up")
    prefix = "ip netns exec atlas-external "
    machine.succeed(prefix + "ip addr add 203.0.113.10/24 dev atlaspeer")
    machine.succeed(prefix + "ip link set atlaspeer up")
    machine.succeed(prefix + "ip link set lo up")
    machine.succeed(prefix + "ip route add default via 203.0.113.1")
    for address in private_probes:
        machine.succeed(prefix + f"ip addr add {address}/32 dev lo")
        machine.succeed(f"ip route add {address}/32 via 203.0.113.10")
    machine.succeed(
        "systemd-run --unit atlas-external-probe --service-type=exec "
        "--property=NetworkNamespacePath=/run/netns/atlas-external "
        f"{probe_python} -m http.server 19091 --bind 0.0.0.0"
    )
    for address, port in [("127.0.0.1", 19090), ("198.51.100.10", 19090)] + [
        (address, 19091) for address in ("203.0.113.10", *private_probes)
    ]:
        machine.wait_until_succeeds(
            f"{probe_python} -c " + shlex.quote(
                f"import socket; socket.create_connection(('{address}', {port}), 2).close()"
            ), timeout=30,
        )


def network_matrix():
    declarations = json.loads(machine.succeed("cat /etc/atlas/host-contract.json"))[
        "configuration"
    ]["environmentEntry"]["environments"]
    addresses = {name: item["network"]["ipv4Address"] for name, item in declarations.items()}
    for name, address in addresses.items():
        instance = "atlas-" + name
        wait_for_instance(instance)
        assert machine.succeed(
            f"incus config device get {instance} eth0 ipv4.address"
        ).strip() == address
        machine.wait_until_succeeds(
            f"incus exec {instance} -T -n -- ip -4 addr show dev eth0 "
            f"| grep -F 'inet {address}/'", timeout=60,
        )
        actual_addresses = json.loads(machine.succeed(
            f"incus exec {instance} -T -n -- ip -j -4 addr show dev eth0"
        ))
        assert address in [item["local"] for item in actual_addresses[0]["addr_info"]]
        # The exact same port can be bound in every environment and on the host.
        machine.succeed(
            f"incus exec {instance} -T -n -- sh -c " + shlex.quote(
                "systemctl stop atlas-guest-probe.service || true; "
                "systemctl reset-failed atlas-guest-probe.service || true; "
                f"mkdir -p /tmp/atlas-network-probe; echo {name} > /tmp/atlas-network-probe/identity; "
                "systemd-run --unit atlas-guest-probe --service-type=exec "
                f"{probe_python} -m http.server 19090 --bind 0.0.0.0 --directory /tmp/atlas-network-probe"
            )
        )
        get_identity = (
            "import urllib.request; "
            f"assert urllib.request.urlopen('http://127.0.0.1:19090/identity', timeout=2).read().decode().strip() == '{name}'"
        )
        machine.wait_until_succeeds(
            f"incus exec {instance} -T -n -- {probe_python} -c {shlex.quote(get_identity)}", timeout=30
        )

    for name, address in addresses.items():
        instance = "atlas-" + name
        # Ubuntu maps its own hostname to 127.0.1.1 in /etc/hosts. Resolve a
        # different environment so this proves DNS, not local host-file lookup.
        dns_peer = "personal-dev" if name == "shared-dev" else "shared-dev"
        # Test one process per source, with explicit denial and positive controls.
        denied = [(other, 19090) for other in addresses.values() if other != address]
        denied += [("10.211.0.1", 19090), ("198.51.100.10", 19090)]
        denied += [(destination, 19091) for destination in private_probes]
        code = (
            "import socket\n"
            f"for address, port in {denied!r}:\n"
            "    try:\n"
            "        connection = socket.create_connection((address, port), 2)\n"
            "    except OSError:\n"
            "        continue\n"
            "    connection.close()\n"
            "    raise AssertionError(f'unexpected reachability: {address}:{port}')\n"
            "socket.create_connection(('203.0.113.10', 19091), 5).close()\n"
            f"resolved = socket.gethostbyname('atlas-{dns_peer}')\n"
            f"assert resolved == {addresses[dns_peer]!r}, resolved\n"
        )
        machine.succeed(
            f"incus exec {instance} -T -n -- {probe_python} -c {shlex.quote(code)} 2>&1"
        )
    return addresses
