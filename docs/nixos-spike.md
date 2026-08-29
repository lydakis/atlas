# NixOS host architecture spike

Status: elastic Btrfs-backed Environment Entry v0 plus encrypted installed-disk
layout validated in QEMU; physical hardware pending

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
3. Durable data belongs to volumes. Atlas automatically manages the human
   owner's conventional home as one volume, while the environment owns its
   resettable root and the `~/.config`, `~/.cache`, `~/.local/bin`, and
   `~/.local/state` views composed over that home. The Btrfs adapter preserves
   the root across reboot until explicit reset, lets it grow with the Atlas data
   filesystem, and supplies cheap root snapshots and restore.
4. Agents are programs using an environment, not environment owners or Linux
   identities. Entry uses the human-owner account with passwordless
   environment-local `sudo`; this broad authority belongs to the environment,
   not to an agent identity.

## Current host contract

The reusable `atlas.host` module currently declares:

- `enable`
- `dataRoot`
- `storage.adapter`
- `owner.name`
- `owner.uid`
- `owner.homeVolumeId`
- `tailscale.enable`
- `tailscale.authKeyFile`
- `tailscale.ssh`
- `volumes`
- `environmentLayers`
- `environments`
- the read-only machine contract

The module serializes that declaration into the versioned host contract. The
Python package under `src/atlas` consumes the contract through three internal
seams: `control` owns the local protocol and peer-derived authorization,
`lifecycle` owns reset and snapshot orchestration, and `storage` owns directory
and Btrfs mechanics. This is an implementation boundary, not a new product
primitive or a remote-management protocol.

Contract version 7 separates three kinds of fact:

- `intent.primitives` names the six product primitives: host, environment,
  volume, grant, surface, and route
- `implementation.primitives` currently contains `host`, `environment`, and
  `volume`
- `configuration` reports static OpenSSH, Tailscale, Nix-authority, and resource
  slice settings plus the Environment Entry v0 adapter without claiming that
  connectivity is active at runtime

The contract also derives its state-directory modes and owners from the same
layout used to generate systemd-tmpfiles rules.

The current configuration adds:

- a fixed v0 state mount point at `/var/lib/atlas`; separate storage must be
  mounted there rather than selecting a broader host directory
- state roots for environments, volumes, grants, credentials, browser profiles,
  recordings, routes, caches, and audit data
- separate `atlas-control.slice` and `atlas-environments.slice` resource lanes
- named environments with explicit opaque IDs, fixed entry UIDs, persistent
  resettable Ubuntu root filesystems and homes, and per-environment resource
  slices
- durable named volumes with explicit target paths and access modes
- ordered reusable non-secret configuration layers with instance overrides
- aliased per-environment package profiles and managed non-secret Git
  configuration
- fixed login shells that start interactive or non-interactive commands in
  persistent, user-namespaced `systemd-nspawn` compartments
- an environment shell wrapper that preserves variables and the declared PATH
  when clients create nested interactive shells
- a socket-activated read-only control service that derives environment identity
  from peer credentials and anchored cgroup membership, plus a separate
  root-only lifecycle service for instance reset
- Btrfs environment roots, read-only applied seeds, named root snapshots, and
  durable-volume subvolumes under `/var/lib/atlas`, with external readiness
  metadata, serialized fail-closed lifecycle changes, and generation-triggered
  environment restart
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

## Environment Entry v0 evidence

The revised Environment Entry v0 integration test passed on August 26, 2026.
It booted the complete AArch64 host under QEMU and verified:

- left-to-right layer composition and instance overrides
- evaluation failure for unknown or repeated layers, duplicate identities or
  UIDs, and caller-defined `ATLAS_` variables
- fixed interactive and non-interactive entry into the same named environment
- a pinned Canonical Ubuntu Noble 24.04 root filesystem for the compartment
- effective environment variables and Atlas identity in both entry modes
- peer-derived `inspect self` identity, with a non-environment UID failing
  closed
- anchored cgroup-derived identity after nspawn moved the payload into its
  machine scope
- mapped root inside the environment without host-root mutation
- a real local Debian package installed with `apt`, persisted across re-entry,
  and remained absent from a neighboring environment
- an `/etc` mutation persisted across re-entry without modifying host `/etc`
- one durable project volume mounted into two development environments and
  omitted from `restricted`
- two development environments with different managed Git identities
- a local repository clone and commit using the effective identity
- operator-only reset rejected from inside an environment
- reset removed the installed package, resettable home, and `/etc` mutation
  while preserving the repository on the attached volume
- nested client shells preserved environment variables and the declared tool
  PATH instead of loading the host-global NixOS PATH
- remote command strings containing shell-variable references reached the
  environment shell without transport-layer expansion
- durable volume data across control-service restart, generation switch, and
  rollback

The persistent-instance hardening revision passed on August 27, 2026. The same
booted-host contract additionally verified:

- one systemd-owned nspawn service per declared environment
- simultaneous entries into the same mutable instance
- workload identity from an anchored service-cgroup prefix, including rejection
  of misleading descendant cgroup names
- separate public inspection and root-only lifecycle sockets
- active workload termination during reset
- stop verification followed by atomic root detachment, with durable volumes
  preserved
- per-environment resettable roots and external readiness markers
- updated environment configuration after generation switch and baseline
  configuration after rollback

The persistent-storage work first replaced tmpfs roots with fixed-size ext4
images below `/var/lib/atlas` and verified persistence across reboot. Product
review rejected the mandatory 1 GiB ceiling: the primary environment must feel
like the machine, not a small container within it. An elastic directory adapter
then proved the corrected lifecycle. The current persistent VM mounts a
dedicated Btrfs data disk and has validated:

- package, `/etc`, ordinary home, and durable-volume persistence across host
  reboot
- reconstruction of `/run` and live execution state after reboot
- elastic use of the Atlas data filesystem with no default per-environment
  quota
- read-only applied seeds and writable copy-on-write roots
- stale applied-seed repair before entry or reset consumes the seed
- named read-only root snapshot creation, listing, restore, and deletion
- explicit snapshot refusal for non-recursive nested Btrfs subvolumes, with
  recursive reset cleanup still succeeding
- snapshot restore removing later root changes while preserving later durable
  volume changes
- explicit COW reset removing package, `/etc`, and home changes while preserving
  the volume
- fail-closed reset when a managed root is replaced by a symbolic link or an
  invalid filesystem object
- resettable root and durable-volume state surviving generation switch and
  rollback

The development adapter reports shared-host networking, encryption, and
storage-reserve policy as degraded. Its resettable roots and named volumes live
on a dedicated but unencrypted Btrfs data filesystem.

The owner-home revision passed the complete x86_64 KVM host contract on August
29, 2026. It verified entry as the configured normal owner UID, passwordless
environment-local `sudo`, a durable home shared by selected environments,
omission from a restricted environment, per-environment resettable home paths,
and preservation of ordinary owner files and a nested project volume across
reboot, root snapshot restore, and explicit reset.

The hardening rerun on August 29 additionally verified that final-component and
intermediate owner-home symlinks fail closed without mutating their host target,
all four resettable home paths persist across reboot and disappear on reset,
ordinary owner files created after a root snapshot survive restore, and a stale
host-owned owner-layout marker blocks entry until explicit reset. The lifecycle
response now reports owner-home preservation from an observed device-and-inode
check rather than from the declaration alone. Snapshot compatibility also
refuses an environment-root symbolic link to that host-owned marker. A later
KVM generation-switch proof detached and reattached the durable home for one
environment: each transition blocked that environment until explicit reset,
preserved the durable owner files, and left an unaffected environment usable.
The existing configuration-only generation switch continued to preserve the
root without requiring reset.

The parameterized x86 installed-storage module is a separate physical-alpha
proof. On August 29, 2026, one fully instantiated KVM acceptance test passed
after it:

- partitioned a disposable 12 GiB GPT disk and installed the declared system
  offline
- booted through UEFI from a LUKS2 container
- resolved the LUKS container and all filesystems through test-installation
  UUIDs rather than reusable labels
- exposed a fixed 6 GiB ext4 host logical volume and used the remaining LVM
  capacity for the Btrfs Atlas data filesystem
- verified the active dm-crypt mapping, distinct mount sources, and reported
  encryption and host-recovery-reserve mechanisms
- preserved resettable environment state, the automatic durable owner home,
  and a declared work volume across reboot
- reset the environment root while preserving both durable storage classes

The automated guest uses a harmless test-only initrd key so the test driver can
boot without a human. The reusable installed-storage module embeds no key and
declares operator-passphrase unlock; the KVM instantiation adds only the test
key. Therefore the test proves the encrypted layout and lifecycle, not the
physical prompt or recovery ceremony.

Tool isolation is also reported as degraded. The environment has an ordinary
Ubuntu filesystem and package manager, while declared Nix tools are available
through a read-only mount of the host Nix store. This is not an executable
allowlist.

## Earlier Tailscale and Herdr dogfood evidence

Before the nspawn and volume revision, the AArch64 development VM was enrolled
interactively into a real Tailscale tailnet and exercised from the host Mac
without a public OpenSSH listener. That fixed-login adapter run verified:

- ordinary Tailscale SSH entry into `shared-dev`, `personal-dev`, and
  `restricted`
- composed variables and distinct managed Git identities over the real SSH
  path
- cloning the public Atlas repository and creating an unpushed local commit in
  `shared-dev` with its configured identity
- denial of a cross-environment home read from `restricted`
- Herdr 0.8.2 installing its matching Linux AArch64 remote binary into the
  environment home and opening its remote TUI
- the Herdr-created shell receiving the composed Atlas variables and managed
  Git configuration

That run also found two interoperability defects: nested interactive shells
loaded the host-global NixOS PATH, and `systemd-run` expanded shell variables in
some remote command strings. The environment shell wrapper and literal command
passthrough fixed both defects in that adapter. The current nspawn adapter has
passed local interactive and non-interactive entry tests, but its exact
Tailscale SSH and Herdr path has not yet been repeated.

Herdr's default managed SSH multiplexing produced intermittent exit status 255
over this Tailscale SSH path. Herdr attached successfully with its local
`[remote].manage_ssh_config = false` setting, which uses plain SSH. Atlas does
not configure Herdr or adopt its session model.

## Security boundary

Environment processes are neither Nix allowed users nor Nix trusted users. They
enter as the human-owner UID and may use passwordless `sudo` inside nspawn. That
environment root is remapped by a user namespace and has no general host sudo
rule. Nix trusted users are effectively root-equivalent because they can
influence privileged builds and substituters, so the spike admits only host
root.

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
- Tailnet policy revocation, long-lived SSH reconnection, and network-change
  behavior have not yet been tested.
- No physical hardware has booted the revised image.
- The installed-host layout has not been exercised through a user-facing
  installer, human passphrase prompt, recovery key, backup, power-loss, or
  metadata-exhaustion flow.
- Resettable roots and durable volumes share the Atlas data filesystem. The
  fixed host logical volume protects capacity structurally in KVM, but recovery
  under real full-disk pressure and optional quotas remain unproven.
- The owner-home implementation and nested resettable home paths passed the KVM
  host and installed-layout proofs but have not yet been exercised on physical
  hardware. Those proofs must be rerun for each change to their mount and
  privilege contract.
- Owner-layout changes, including changes to the copied environment-local
  sudo/PAM support closure, deliberately require explicit environment reset.
  Atlas has no in-place migration framework for mutable roots yet. Snapshots
  from an older owner layout are rejected rather than relabeled as current.
- The fixed login adapter and Herdr have not yet been exercised on physical
  hardware, and Codex has not yet been tested as a remote target.
- Runtime creation and deletion of definitions or volumes is not implemented.
  The split local control services can inspect and reset only declared
  environments.
- Each declared environment has one persistent service and supports concurrent
  entry. Atlas does not yet reconstruct client-owned PTYs or define a durable
  task supervisor above ordinary Linux process tools.
- Environment networking is shared with the host, and the host Nix store is
  visible read-only. Stronger network and tool isolation remain undecided.
- There is no browser or display broker, grant broker, route proxy, audit
  service, or update controller.
- There is no Secure Boot, measured boot, signed Atlas release metadata,
  anti-downgrade policy, or failed-health automatic rollback.
- No real enrollment key or secret lifecycle has been tested. Evaluation uses
  only harmless representative paths.

## Reproducing the spike

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

Without Nix, the pinned container helper uses the named Docker volume
`atlas-nix-store`:

```bash
docker volume create atlas-nix-store
./scripts/nix-container flake check path:/workspace --all-systems --no-build
./scripts/nix-container build path:/workspace#checks.aarch64-linux.control-unit --no-link
./scripts/nix-container build path:/workspace#checks.aarch64-linux.module-evaluation --no-link
./scripts/nix-container build path:/workspace#checks.aarch64-linux.host-contract --no-link
./scripts/nix-container build path:/workspace#packages.aarch64-linux.vm --no-link
./scripts/nix-container build path:/workspace#packages.aarch64-linux.physical-iso --no-link
```

For the physical live-image flow and its security limits, see
[Physical host v0](physical-host-v0.md).

## Architecture decision boundary

The [roadmap](roadmap.md) is the sole authority for future implementation order.
This report records NixOS-adapter evidence and the unproven gaps above rather
than maintaining a second sequence.

NixOS remains a provisional vehicle. Compare it with a bootc/OCI host only after
the required product behavior is concrete enough to port and measure on both
adapters.
