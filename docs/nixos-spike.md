# NixOS host architecture spike

Status: physical-first revision validated in QEMU, physical boot pending

## Outcome

NixOS remains the Atlas prototype vehicle, but it is not selected permanently.

The original spike validated the static and mutable split:

```text
Pinned host plane                 Mutable Atlas data plane
----------------                 ------------------------
kernel and boot policy           environments
firewall and private access      browser profiles
control and environment slices   grants and credentials
system services                  routes and recordings
system generations               audit data
```

Mutable Atlas data lives under `/var/lib/atlas`, outside `/nix/store`, and
survived a live switch to a second system generation and rollback to the first.

The revision after the product-boundary discussion makes two corrections:

1. The product target is a dedicated physical computer. VM outputs remain
   development, automated-test, and optional deployment artifacts.
2. Atlas environments are OS compartments used by existing agent clients. They
   are not repositories, worktrees, conversations, terminals, or tasks.

## Current host contract

The reusable `atlas.host` module currently declares:

- `enable`
- `dataRoot`
- `tailscale.enable`
- `tailscale.authKeyFile`
- `tailscale.ssh`
- the read-only machine contract

Contract version 3 separates three kinds of fact:

- `intent.primitives` names the five product primitives: host, environment,
  grant, surface, and route
- `implementation.primitives` currently contains only `host`
- `configuration` reports static OpenSSH, Tailscale, Nix-authority, and resource
  slice settings without claiming that connectivity is active at runtime

The contract also derives its state-directory modes and owners from the same
layout used to generate systemd-tmpfiles rules.

The current configuration adds:

- a fixed v0 state mount point at `/var/lib/atlas`; separate storage must be
  mounted there rather than selecting a broader host directory
- state roots for environments, grants, credentials, browser profiles,
  recordings, routes, caches, and audit data
- separate `atlas-control.slice` and `atlas-environments.slice` resource lanes
- a Tailscale daemon and interactive `atlas-enroll` helper
- optional unattended enrollment from a canonical external runtime auth-key
  path; Nix path values, Nix store aliases, and resolved store targets are
  rejected before enrollment
- Tailscale SSH requested during enrollment
- no OpenSSH service or public TCP port 22
- a live physical ISO with local-console enrollment instructions

## Original validated evidence

| Check | Result |
| --- | --- |
| Evaluate module, VM, ISO, test, and formatter outputs on both architectures | pass |
| Build AArch64 VM | pass |
| Build AArch64 live ISO | pass |
| Boot the AArch64 system under QEMU TCG on Apple Silicon | pass |
| Start the Atlas readiness target | pass |
| Put host validation in `atlas-control.slice` | pass |
| Put both demonstration processes in the lower-weight environment slice | pass |
| Give the two demonstrations different network namespaces | pass |
| Run both on `127.0.0.1:3000` without collision | pass |
| Keep Nix daemon access and trusted-user authority root-only | pass |
| Create the credential directory as `0700 atlas-control:atlas-control` | pass |
| Switch to an updated generation and back to baseline | pass |
| Preserve mutable state across the switch and rollback | pass |

The software-emulated guest reported 87.6 seconds from boot to multi-user
readiness. The complete integration test took 137.1 seconds. Those are QEMU TCG
validation timings, not performance measurements.

The original live ISO file was 630 MiB. The VM runner's full Nix closure was
2.5 GiB, much of which was host-side QEMU. Size optimization was not a goal.

## Physical-first revision evidence

The revised AArch64 integration test passed on August 25, 2026. It verified:

- contract version 3 and the separation of intent, implementation, and static
  configuration
- the state roots and their generated permissions and ownership
- Tailscale daemon startup without requiring enrollment
- availability of the interactive `atlas-enroll` helper
- absence of the OpenSSH service
- both demonstrations in `atlas-environments.slice` and distinct network
  namespaces
- declarative generation update and rollback with state written by a dynamic
  environment service preserved
- a fresh AArch64 physical ISO build, approximately 646 MiB

The final software-emulated QEMU test took 334.7 seconds on a loaded development
machine. This is validation timing, not a performance measurement. It validates
the host configuration, not Tailscale authentication against a real tailnet or
behavior on physical hardware.

## Security boundary

Environment processes are neither Nix allowed users nor Nix trusted users. Nix
trusted users are effectively root-equivalent because they can influence
privileged builds and substituters, so the spike admits only root.

The optional Tailscale auth-key setting accepts a canonical external runtime
path string, not a Nix path or secret value. Evaluation tests reject Nix path
values, Nix store paths, and dot-segment aliases. Before enrollment, the service
resolves the runtime path and refuses a target inside `/nix/store`. An ordinary
`/run/secrets/...` path remains unchanged in the generated enrollment script.
Interactive enrollment is the default. Private keys, auth keys, tokens,
cookies, browser profiles, and recovery material must never be interpolated
into Nix expressions or derivations.

Tailscale supplies private reachability and SSH authentication according to the
tailnet policy. Permission to log in as `atlas-operator` is host-administrator
authority in this spike because that account has passwordless sudo. Tailnet
policy must treat it accordingly.

## What this does not prove

- The physical ISO is still a live image, not a persistent installer or
  flash-to-disk appliance image.
- Local-console autologin is present only to dogfood enrollment from the live
  image. It is not acceptable for the persistent product.
- Tailscale enrollment against a real tailnet, policy revocation, SSH
  reconnection, and network-change behavior have not yet been tested.
- No physical hardware has booted the revised image.
- `/var/lib/atlas` is not a dedicated encrypted partition with backup and
  recovery behavior.
- The two demonstration processes prove selected systemd and kernel primitives,
  not an interactive environment that an agent client can enter.
- There is no Atlas control daemon, environment manager, browser or display
  broker, grant broker, route proxy, audit service, or update controller.
- There is no Secure Boot, measured boot, signed Atlas release metadata,
  anti-downgrade policy, or failed-health automatic rollback.
- No real enrollment key or secret lifecycle has been tested. Evaluation uses
  only harmless representative paths.

## Reproducing the spike

With Nix installed:

```bash
nix flake check --all-systems --no-build
nix build .#checks.aarch64-linux.module-evaluation
nix build .#checks.aarch64-linux.host-contract
nix build .#packages.aarch64-linux.vm
nix build .#packages.aarch64-linux.physical-iso
```

Without Nix, the pinned container helper uses the named Docker volume
`atlas-nix-store`:

```bash
docker volume create atlas-nix-store
./scripts/nix-container flake check path:/workspace --all-systems --no-build
./scripts/nix-container build path:/workspace#checks.aarch64-linux.module-evaluation --no-link
./scripts/nix-container build path:/workspace#checks.aarch64-linux.host-contract --no-link
./scripts/nix-container build path:/workspace#packages.aarch64-linux.vm --no-link
./scripts/nix-container build path:/workspace#packages.aarch64-linux.physical-iso --no-link
```

For the physical live-image flow and its security limits, see
[Physical host v0](physical-host-v0.md).

## Architecture decision sequence

NixOS is now used as a provisional vehicle to answer the product question. The
next gates are:

1. Boot the live image on one representative x86 computer and validate
   interactive Tailscale SSH without a public listener.
2. Implement and test a persistent disk and recovery design, including encrypted
   state and one declared automatic or operator-assisted unlock mode.
3. Build one environment that an existing agent client can enter as a normal
   remote Linux target.
4. Implement the [Authenticated Surface v0](authenticated-surface-v0.md)
   contract, add one tailnet-private route, and prove a second environment
   cannot cross those boundaries.
5. Port that concrete behavior to a bootc/OCI spike and compare host definition,
   installation, updates, rollback, recovery, toolchain delivery, and operator
   complexity.

The base should be selected from equivalent product behavior, not before that
behavior exists.
