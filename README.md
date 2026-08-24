# Atlas

**An operating environment for computers whose primary user is software.**

Atlas explores what changes when a machine is designed from the start to run
software agents. It is the host layer beneath tools such as the Codex app, T3
Code, Herdr, Blue, SSH, and agent CLIs. Those tools decide what an agent does
and how a person interacts with it. Atlas aims to make the underlying computer
durable, isolated, observable, and recoverable.

> [!IMPORTANT]
> Atlas is an early architecture exploration, not an installable product. This
> repository currently contains a validated NixOS host spike and the product
> contracts it is meant to test. The base operating system is not yet decided.

## The idea

Giving an agent a remote shell is easy. Giving it a complete computer that can
continue after a client disconnects, safely use credentials and browsers, show
its work, survive updates, and be recovered by an operator is not.

Atlas proposes a stable machine layer:

```text
Codex app · T3 Code · Herdr · SSH · Blue · any agent CLI
                         │
              stable local host contract
                         │
     workspace · workload · preview · browser · identity
                         │
          Atlas image or supported Linux install
                         │
                physical machine or VM
```

Atlas is not an agent harness, chat interface, IDE, model runtime, or
orchestration framework. It should work with all of them.

## What exists today

The first spike tests whether NixOS can provide a credible managed-host
foundation. It includes:

- a pinned NixOS 26.05 configuration for `aarch64-linux` and `x86_64-linux`
- buildable headless QEMU VM and live ISO outputs
- a reusable `atlas.host` NixOS module
- a machine-readable host contract at `/etc/atlas/host-contract.json`
- a mutable data boundary under `/var/lib/atlas`, outside the Nix store
- separate resource lanes for the Atlas control plane and agent workloads
- locked-down remote access that is disabled until operator SSH keys are supplied
- two isolated demonstration workloads that can use the same local port without colliding
- a QEMU integration test covering boot, isolation, update, rollback, and state preservation

The spike passed on Apple Silicon using a software-emulated AArch64 guest. See
the [NixOS spike report](docs/nixos-spike.md) for the evidence and limitations.

## What does not exist yet

There is no Atlas daemon, CLI, pairing flow, browser service, preview router,
credential broker, audit service, or update controller. The ISO is a live boot
artifact, not a persistent installer or production image. Disk encryption,
Secure Boot, signed releases, automatic failed-update recovery, and physical
hardware validation remain future work.

In short, this repository proves parts of the host substrate. It does not yet
deliver the agent-computer experience described by the thesis.

## Try the architecture spike

With Nix installed:

```bash
nix flake check --all-systems --no-build
nix build .#checks.aarch64-linux.host-contract
nix build .#packages.aarch64-linux.vm
nix build .#packages.aarch64-linux.iso
```

Without Nix, use Docker and the pinned helper image:

```bash
docker volume create atlas-nix-store
./scripts/nix-container flake check path:/workspace --all-systems --no-build
./scripts/nix-container build path:/workspace#checks.aarch64-linux.host-contract --no-link
./scripts/nix-container build path:/workspace#packages.aarch64-linux.vm --no-link
./scripts/nix-container build path:/workspace#packages.aarch64-linux.iso --no-link
```

Replace `aarch64-linux` with `x86_64-linux` for an x86 output.

## Design principles

- **Interface-independent:** existing agent clients should benefit without becoming Atlas-specific clients.
- **Headless, not blind:** a person can inspect, approve, observe, take over, and recover work.
- **Durable by declaration:** named files and services survive or reconstruct; arbitrary process memory does not.
- **Scoped authority:** workloads receive explicit capabilities, not ambient host secrets or root-equivalent build access.
- **Private by default:** discovering a service does not publish it.
- **Local-first:** the core machine remains useful without an Atlas-operated cloud.
- **Evidence over branding:** Atlas should own the OS only where that produces measurable isolation, reliability, or recovery gains.

## Architecture decision still open

NixOS is the leading candidate after the first spike, not a commitment. The
next comparison is a bootc/OCI-based host implementing the same contract. The
project should choose the base only after both can be tested for persistent
installation, encrypted state, transactional updates, failed-health recovery,
untrusted toolchain installation, and representative physical hardware.

## Documentation

- [Product thesis](docs/product-thesis.md)
- [Interop contract](docs/interop-contract.md)
- [Threat model](docs/threat-model.md)
- [NixOS architecture spike](docs/nixos-spike.md)

## Contributing

Atlas is at the thesis and architecture-spike stage. Issues that challenge the
product boundary, propose measurable host guarantees, or compare implementation
approaches are especially useful. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Atlas is available under the [MIT License](LICENSE).
