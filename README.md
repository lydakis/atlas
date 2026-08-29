# Atlas

**An operating environment for computers whose primary user is software.**

Atlas explores what changes when a physical computer is designed from the start
to run software agents. It is the host layer beneath tools such as the Codex
app, T3 Code, Herdr, Blue, SSH, and agent CLIs. Those tools decide what an
agent does and how a person interacts with it. Atlas aims to make the
underlying computer private, isolated, observable, and recoverable.

> [!IMPORTANT]
> Atlas is an early architecture exploration, not an installable product. This
> repository currently contains a validated NixOS host spike and the product
> contracts it is meant to test. The base operating system is not yet decided.

## The idea

Giving an agent a remote shell is easy. Giving it a complete computer that can
continue after a client disconnects, safely use credentials and browsers, show
its work, survive updates, and be recovered by an operator is not.

Atlas proposes a stable machine layer without replacing the agent interface:

```text
Codex app · T3 Code · Herdr · SSH · Blue · any agent CLI
                         │
             ordinary remote connection
                         │
    environment · volume · grant · surface · route
                         │
                   Atlas host
                         │
              dedicated physical machine
```

Atlas is not an agent harness, chat interface, IDE, model runtime, project
manager, Git workflow, or orchestration framework. Existing clients continue to
own repositories, worktrees, terminals, tasks, and conversations.

## What exists today

The first spike tests whether NixOS can provide a credible managed-host
foundation. The product target is dedicated physical hardware; VMs are
development, automated-test, and optional deployment artifacts. The spike
includes:

- a pinned NixOS 26.05 configuration for `aarch64-linux` and `x86_64-linux`
- buildable headless QEMU VM and physical live-ISO outputs
- a parameterized x86 installed-storage module requiring installer-generated
  device UUIDs, with UEFI boot, one LUKS2 container, and separate fixed host
  and elastic Btrfs data logical volumes
- a reusable `atlas.host` NixOS module
- a versioned static host contract at `/etc/atlas/host-contract.json` that
  separates product intent, implemented primitives, and configured mechanisms
- a mutable data boundary under `/var/lib/atlas`, outside the Nix store
- state roots for environments, volumes, grants, browser profiles, recordings,
  and routes
- separate resource lanes for the Atlas control plane and agent environments
- reusable non-secret configuration, package, and Git-profile layers with
  named environment definitions
- fixed environment login targets that enter persistent, user-namespaced Ubuntu
  Noble compartments supervised by systemd
- resettable environment roots, with explicit durable volumes composed inside
  their ordinary Linux view and shareable across selected environments
- elastic Btrfs environment roots under `/var/lib/atlas` that preserve ordinary
  machine state across reboot without an arbitrary default quota
- read-only applied seeds plus root snapshot, restore, and delete operations;
  durable volumes remain outside root snapshots
- mapped root inside an environment, so agents can install ordinary Debian
  packages and mutate their OS without receiving host root
- a peer-authenticated read-only control socket for doctor, list, and inspect,
  plus a separate root-only lifecycle socket for environment reset and root
  snapshots
- a Tailscale enrollment helper that enables tailnet-private SSH
- no publicly exposed OpenSSH service
- two development environments with different Git identities plus one minimal
  environment without Git on its declared PATH
- a QEMU integration test covering persistent and concurrent entry,
  composition, shared-volume access, package installation, host reboot,
  elastic Btrfs storage, root snapshot restore, volatile-state reconstruction,
  active-workload reset, identity, isolation, update, rollback, and
  durable-volume preservation
- an x86 KVM installed-disk acceptance test covering offline installation,
  encrypted boot, storage-capacity separation, reboot, reset, and declared
  durable-volume preservation
- an earlier live-tailnet dogfood run using ordinary Tailscale SSH and Herdr's
  remote thin client against the preceding fixed-login adapter

The current nspawn and volume contract passed on Apple Silicon using a
software-emulated AArch64 guest. The earlier adapter was also enrolled into a
real tailnet and entered as all three declared environments without exposing a
public SSH listener. The current adapter's exact Tailscale and Herdr path still
needs to be repeated. See the [NixOS spike report](docs/nixos-spike.md) for the
evidence and limitations.

## What does not exist yet

The local control plane is a deliberately tiny v0, not a runtime environment
manager. Its split sockets can inspect and reset declared instances, but cannot
create environment definitions or volumes at runtime. There is no operator
console, browser service, grant broker, route proxy, audit service, or update
controller.
The ISO can exercise interactive Tailscale enrollment on hardware, but it is a
live boot artifact rather than a persistent installer or production image. An
encrypted installed-disk layout now passes in x86 KVM using a test-only initrd
key; the real operator passphrase ceremony, physical hardware, Secure Boot,
signed releases, and automatic failed-update recovery remain unproven.

Each environment now has one persistent nspawn service. Entries join that
service through Linux namespaces and a delegated session cgroup, so concurrent
clients see one instance and reset can terminate the complete workload tree.
The persistent VM now mounts a dedicated Btrfs disk at `/var/lib/atlas`.
Resettable roots and durable volumes are separate subvolumes; roots persist
across reboot, reset cheaply from read-only applied seeds, and support named
snapshots and restore. The primary environment is not artificially capped. A
protected host recovery reserve, optional quotas for additional environments,
durable-volume snapshots and backup, at-rest encryption, power-loss recovery,
and physical-hardware validation remain incomplete.
Networking is shared with the host, and the read-only Nix store is visible for
declared tools. These gaps are reported rather than hidden.

In short, this repository proves parts of the host substrate. It does not yet
deliver the agent-computer experience described by the thesis.

## Try the architecture spike

With Nix installed:

```bash
nix flake check --all-systems --no-build
nix build .#checks.aarch64-linux.control-unit
nix build .#checks.aarch64-linux.module-evaluation
nix build .#checks.aarch64-linux.host-contract
nix build .#checks.x86_64-linux.installed-host
nix build .#packages.aarch64-linux.vm
nix build .#packages.aarch64-linux.physical-iso
```

Without Nix, use Docker and the pinned helper image:

```bash
docker volume create atlas-nix-store
./scripts/nix-container flake check path:/workspace --all-systems --no-build
./scripts/nix-container build path:/workspace#checks.aarch64-linux.control-unit --no-link
./scripts/nix-container build path:/workspace#checks.aarch64-linux.module-evaluation --no-link
./scripts/nix-container build path:/workspace#checks.aarch64-linux.host-contract --no-link
./scripts/nix-container build path:/workspace#packages.aarch64-linux.vm --no-link
./scripts/nix-container build path:/workspace#packages.aarch64-linux.physical-iso --no-link
```

Replace `aarch64-linux` with `x86_64-linux` for an x86 output.

The Docker path on Apple Silicon runs the VM tests under software-emulated
QEMU with no KVM. If a Linux machine with Nix and `/dev/kvm` is reachable over
SSH, `scripts/remote-check` syncs the working tree there and runs checks with
hardware acceleration instead:

```bash
scripts/remote-check                                        # nix flake check
scripts/remote-check build .#checks.x86_64-linux.host-contract
scripts/remote-check build .#checks.x86_64-linux.installed-host --no-link
```

Set `ATLAS_BUILD_HOST` to choose the ssh destination.

## Design principles

- **Existing-client first:** an Atlas environment should look like a normal remote Linux target.
- **Headless, not blind:** a person can inspect, approve, observe, take over, and recover work.
- **Persistent by default, durable by declaration:** ordinary environment files
  survive reboot and update; explicit resettable machine state may be
  discarded; declared volumes survive environment reset; live process memory
  and connections do not survive reboot.
- **Agents are processes, not identities:** humans own environments and durable
  data; several agents may concurrently use the same environment.
- **Scoped authority:** environments receive explicit grants, not ambient host secrets or root-equivalent build access.
- **Private by default:** network reachability and port discovery do not publish a service.
- **Local-first:** the core machine remains useful without an Atlas-operated cloud.
- **Evidence over branding:** Atlas should own the OS only where that produces measurable isolation, reliability, or recovery gains.

## Architecture decision still open

NixOS is the current prototype vehicle, not a commitment. The
[roadmap](docs/roadmap.md) records the current proof sequence and status. A
bootc/OCI comparison waits until the required product behavior is concrete
enough to port and compare honestly.

## Documentation

- [Documentation map](docs/README.md)
- [Product thesis](docs/product-thesis.md)
- [Roadmap](docs/roadmap.md)
- [Environment Entry v0](docs/environment-entry-v0.md)
- [Persistent Storage v0](docs/persistent-storage-v0.md)
- [Authenticated Surface v0](docs/authenticated-surface-v0.md)
- [Interop contract](docs/interop-contract.md)
- [Threat model](docs/threat-model.md)
- [Physical host v0](docs/physical-host-v0.md)
- [NixOS architecture spike](docs/nixos-spike.md)

## Contributing

Atlas is at the thesis and architecture-spike stage. Issues that challenge the
product boundary, propose measurable host guarantees, or compare implementation
approaches are especially useful. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Atlas is available under the [MIT License](LICENSE).
