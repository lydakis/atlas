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
       environment · grant · surface · route
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
- a reusable `atlas.host` NixOS module
- a versioned static host contract at `/etc/atlas/host-contract.json` that
  separates product intent, implemented primitives, and configured mechanisms
- a mutable data boundary under `/var/lib/atlas`, outside the Nix store
- state roots for environments, grants, browser profiles, recordings, and routes
- separate resource lanes for the Atlas control plane and agent environments
- a Tailscale enrollment helper that enables tailnet-private SSH
- no publicly exposed OpenSSH service
- two isolated demonstration environments that can use the same local port without colliding
- a QEMU integration test covering boot, isolation, update, rollback, and state preservation

The spike passed on Apple Silicon using a software-emulated AArch64 guest. See
the [NixOS spike report](docs/nixos-spike.md) for the evidence and limitations.

## What does not exist yet

There is no Atlas control daemon, operator console, environment manager,
browser service, grant broker, route proxy, audit service, or update controller.
The ISO can exercise interactive Tailscale enrollment on hardware, but it is a
live boot artifact rather than a persistent installer or production image. Disk
encryption, Secure Boot, signed releases, automatic failed-update recovery, and
physical-hardware validation remain future work.

In short, this repository proves parts of the host substrate. It does not yet
deliver the agent-computer experience described by the thesis.

## Try the architecture spike

With Nix installed:

```bash
nix flake check --all-systems --no-build
nix build .#checks.aarch64-linux.module-evaluation
nix build .#checks.aarch64-linux.host-contract
nix build .#packages.aarch64-linux.vm
nix build .#packages.aarch64-linux.physical-iso
```

Without Nix, use Docker and the pinned helper image:

```bash
docker volume create atlas-nix-store
./scripts/nix-container flake check path:/workspace --all-systems --no-build
./scripts/nix-container build path:/workspace#checks.aarch64-linux.module-evaluation --no-link
./scripts/nix-container build path:/workspace#checks.aarch64-linux.host-contract --no-link
./scripts/nix-container build path:/workspace#packages.aarch64-linux.vm --no-link
./scripts/nix-container build path:/workspace#packages.aarch64-linux.physical-iso --no-link
```

Replace `aarch64-linux` with `x86_64-linux` for an x86 output.

## Design principles

- **Existing-client first:** an Atlas environment should look like a normal remote Linux target.
- **Headless, not blind:** a person can inspect, approve, observe, take over, and recover work.
- **Durable by declaration:** named state and services survive or reconstruct; arbitrary process memory does not.
- **Scoped authority:** environments receive explicit grants, not ambient host secrets or root-equivalent build access.
- **Private by default:** network reachability and port discovery do not publish a service.
- **Local-first:** the core machine remains useful without an Atlas-operated cloud.
- **Evidence over branding:** Atlas should own the OS only where that produces measurable isolation, reliability, or recovery gains.

## Architecture decision still open

NixOS is the current prototype vehicle, not a commitment. The next product
proof follows the product-thesis checklist on physical hardware. Authenticated
Surface v0 supplies its browser and takeover security boundary; the same proof
also exercises environment entry, capability reporting, one private route,
reboot, update, and a second environment that cannot cross those boundaries. A
bootc/OCI comparison follows once that behavior is concrete enough to port and
compare honestly.

## Documentation

- [Product thesis](docs/product-thesis.md)
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
