# NixOS host architecture spike

Status: completed architecture spike, August 22, 2026

## Outcome

NixOS remains the leading Atlas base candidate, but it is not selected yet.

The spike validates the core architectural split:

```text
Pinned host plane                 Mutable Atlas data plane
----------------                 ------------------------
kernel and boot policy           workspaces
firewall and remote access       browser profiles
control and workload slices      caches
system services                  credentials loaded at runtime
system generations               audit data
```

NixOS can own the static host without making workspaces part of a system rebuild. Atlas data lives under `/var/lib/atlas`, outside `/nix/store`, and survived a live switch to a second system generation and a rollback to the first.

This is enough to continue with NixOS. It is not enough to choose it permanently.

## What was built

- NixOS 26.05 pinned to nixpkgs commit `5880666fd9eb563038431edb35c2d0aa595884e6`
- a reusable `atlas.host` NixOS module with only three public options:
  - `enable`
  - `dataRoot`
  - `operatorAuthorizedKeys`
- a machine-readable host contract at `/etc/atlas/host-contract.json`
- a headless QEMU VM output for `aarch64-linux` and `x86_64-linux`
- a live ISO output for both architectures
- two hostile-by-assumption demonstration services, each with a dynamic OS user, its own network namespace, no Linux capabilities, a read-only host filesystem view, and the same local port
- separate systemd slices for Atlas control-plane and workload processes
- a NixOS integration test that boots a real kernel under QEMU

The local fallback build environment uses the official Nix 2.35.2 container pinned to image digest `sha256:7a007c766426c1877758ddc5cb87a965ac131fc78c582ce0083d922d51ae945c`.

## Evidence

| Check | Result |
| --- | --- |
| Evaluate module, VM, ISO, test, and formatter outputs on both architectures | pass |
| Build aarch64 VM | pass |
| Build aarch64 live ISO | pass |
| Boot the aarch64 system under QEMU TCG on Apple Silicon | pass |
| Start the Atlas readiness target | pass |
| Put host validation in `atlas-control.slice` | pass |
| Put both workloads in `atlas-workloads.slice` | pass |
| Give the two workloads different network namespaces | pass |
| Run both workloads on `127.0.0.1:3000` without collision | pass |
| Keep Nix daemon access and trusted-user authority root-only | pass |
| Create the credential directory as `0700 atlas-control:atlas-control` | pass |
| Switch from the baseline generation to an updated generation | pass |
| Preserve a mutable workspace probe across the switch | pass |
| Roll back to the baseline generation | pass |
| Preserve the workspace probe across rollback | pass |

The final software-emulated guest reported 87.6 seconds from boot to multi-user readiness. The complete integration test took 137.1 seconds. These are validation timings under QEMU TCG, not performance measurements.

The final live ISO file was 630 MiB. The VM runner's full Nix closure was 2.5 GiB, much of which was host-side QEMU. Artifact-size optimization was not a goal of this spike.

## Security boundary

Workloads are neither Nix allowed users nor Nix trusted users. Nix trusted users are effectively root-equivalent because they can influence privileged builds and substituters, so the spike admits only root. A future package-install experience must use an Atlas-controlled builder, an unprivileged container boundary, or another mediated mechanism. It must not make agent workloads trusted Nix users.

The configuration accepts public SSH keys, not secret values. SSH and port 22 remain disabled when no operator key is supplied. No secret-delivery system exists yet. Future private keys, tokens, cookies, and recovery material must enter at runtime and must never be interpolated into Nix expressions or derivations, where they could become readable store paths.

## What this does not prove

- The ISO is a live boot artifact, not yet a persistent install or flash image.
- The test switches system closures in a running VM. It does not yet test rebooting into a new bootloader generation and selecting the previous generation after a failed health check.
- `/var/lib/atlas` is logically separate but not yet a dedicated encrypted partition with a backup and recovery design.
- The two workloads prove systemd and kernel primitives, not the final container, user-namespace, or microVM boundary.
- There is no Atlas daemon, CLI, pairing ceremony, browser, preview router, credential broker, audit service, or update controller.
- There is no secure boot, measured boot, disk encryption, signed Atlas release metadata, or anti-downgrade policy.
- No physical hardware has booted this configuration.
- The Docker-hosted Nix builder cannot enable Nix's nested build sandbox without privileged Docker. The resulting NixOS runtime does enable its own Nix sandbox, but this local build is not supply-chain evidence.
- No secret-handling claim has been tested because the spike intentionally contains no secrets.

## Comparison target: bootc

bootc is the right next comparison, not a traditional mutable Ubuntu installer. It provides transactional in-place OS updates using OCI images, and the Fedora image-mode ecosystem already treats `/var` as mutable state across OS replacement. That makes it a credible appliance base rather than a straw man.

| Criterion | NixOS spike | bootc hypothesis to test |
| --- | --- | --- |
| Host definition | typed, composable Nix modules and a fully pinned dependency graph | Containerfile plus systemd/config files in a signed OCI image |
| Update unit | system closure and generations | bootable OCI image |
| Rollback | multiple generations, live activation, and boot selection | transactional image rollback, normally applied with reboot |
| Mutable state | Atlas must explicitly keep state outside `/nix/store` | image model already separates OS content from `/var`; `/etc` semantics need testing |
| Auditability | source declaration exposes option values and dependency inputs | Containerfile and image digest are familiar, but arbitrary build steps may hide more intent |
| Ecosystem | broad Nix package set and strong per-host composition | Fedora/RPM and OCI tooling, with a more conventional image pipeline |
| Operator complexity | unusual language and deployment model | familiar container build, registry, signing, and promotion workflow |
| Dynamic agent installs | must be mediated outside the host generation | should also be kept out of the bootable host image and mediated in workloads |

NixOS should win if Atlas is fundamentally a machine-policy product whose guarantees are most clearly expressed, checked, and reconstructed as configuration. bootc should win if Atlas becomes primarily a fixed OS image plus a portable daemon, because OCI-native build, signing, promotion, and update operations would then be the simpler product architecture.

Official references:

- [NixOS manual](https://nixos.org/manual/nixos/stable/)
- [Nix trusted-user configuration](https://nix.dev/manual/nix/2.34/command-ref/conf-file.html#conf-trusted-users)
- [bootc architecture](https://bootc.dev/bootc/)
- [bootc update service](https://bootc.dev/bootc/man/bootc-fetch-apply-updates.service.5.html)
- [rpm-ostree update and state model](https://coreos.github.io/rpm-ostree/)

## Reproducing the spike

With Nix installed:

```bash
nix flake check --all-systems --no-build
nix build .#checks.aarch64-linux.host-contract
nix build .#packages.aarch64-linux.vm
nix build .#packages.aarch64-linux.iso
```

On this Mac, where Nix is not installed, the pinned container helper uses the named Docker volume `atlas-nix-store`:

```bash
docker volume create atlas-nix-store
./scripts/nix-container flake check path:/workspace --all-systems --no-build
./scripts/nix-container build path:/workspace#checks.aarch64-linux.host-contract --no-link
./scripts/nix-container build path:/workspace#packages.aarch64-linux.vm --no-link
./scripts/nix-container build path:/workspace#packages.aarch64-linux.iso --no-link
```

## Next decision gate

Do not expand the Nix module into an Atlas implementation yet. The next spike should answer four questions:

1. Can a bootc image express and test the same host contract with less product-specific machinery?
2. Can each base install to a persistent encrypted disk, update, fail a health check, reboot, and automatically recover while preserving `/var/lib/atlas`?
3. Can an untrusted workload obtain a disposable toolchain without mutating the host or receiving root-equivalent build authority?
4. Can the resulting artifact boot on one representative x86 machine and one representative ARM machine with a credible recovery path?

Choose the base only after that gate.
