# Atlas roadmap

Status: working product sequence, revised August 2026

This document tracks the next product proofs and the decisions that constrain
them. The product thesis and interoperability contracts remain authoritative;
completed claims require evidence in the spike reports and tests.

Atlas does not need a separate project-management system yet. The work is still
primarily one architecture and one implementation, and keeping the sequence next
to the contracts makes changes reviewable with the code. GitHub issues or a
dedicated external tracker become useful when several contributors, releases, or
independent workstreams need assignment and coordination.

## Current product shape

- One default environment is the normal experience. Additional environments are
  explicit boundaries for different authority, network policy, incompatible
  toolchains, reset policy, or resource limits, not a requirement per
  project or agent.
- The human owns the box, account, and data. An agent is a program operating in
  an environment, not a Linux identity or the owner of that environment.
- Agent-visible files persist by default. Ordinary files, installed packages,
  `/etc`, and the environment home should survive disconnect, environment
  restart, host reboot, and supported update.
- An explicit environment reset discards resettable machine state while leaving
  attached durable volumes intact.
- Repositories remain ordinary data on volumes. Atlas does not own projects,
  worktrees, conversations, or coding sessions.
- Non-secret environment configuration may eventually have a portable,
  declarative representation. Repository-carried definitions are untrusted
  suggestions and are never applied or executed ambiently.
- Secrets are grants, not environment configuration. Portable environment
  definitions do not contain secret material.
- Incus 7.0 LTS is the selected Environment substrate. It remains behind the
  Atlas lifecycle boundary; systemd-nspawn is a temporary reference until the
  Incus adapter passes the existing contracts.

## Persistence vocabulary

Atlas distinguishes three lifecycle classes.

### Durable data

Operator-owned volumes contain repositories, worktrees, datasets, and artifacts
that must survive environment reset. Their documented policy may additionally
cover update, recovery, backup, and machine loss. Durability is an explicit
promise, not a consequence of a path happening to be on disk.

### Resettable machine state

The environment root contains installed packages, `/etc`, caches, tool
configuration, and the environment-local home paths declared below. The product
default is disk-backed and persistent until the operator deliberately resets or
deletes the environment. It survives disconnect, process failure, host reboot,
and supported update, but it is not implicitly backed up and is not protected
from explicit reset.

Atlas gives the single human owner a conventional `/home/<owner>` backed by an
automatically managed durable volume. An environment may attach that home, then
overlay `~/.config`, `~/.cache`, `~/.local/bin`, and `~/.local/state` from its
resettable root. `~/.local/share` and ordinary owner files are durable in v0.
This is an explicit path contract, not a claim that Atlas recognizes every
configuration dotfile. Environments that omit owner-home access receive a
private resettable home instead.

Copy-on-write reconstruction and atomic root replacement are now proven by the
Btrfs adapter. Quota enforcement remains absent. Agents should not need to
choose special paths merely to keep ordinary files across a reboot.

### Volatile execution state

Process memory, kernel process state, open file descriptors, network
connections, transient sockets, locks, PID files, mount state, and `/run` cannot
meaningfully survive a normal reboot. Declared services may restart from their
persistent files, but Atlas does not promise to resume arbitrary process memory
or connection-local terminal state.

Conventional temporary locations may be cleared according to an explicit and
discoverable policy. Atlas must not silently classify ordinary home or root
filesystem contents as volatile. Deliberately ephemeral environments may exist
later, but they are an opt-in policy rather than the default experience.

## Product proof critical path

The table records the dependency-shaped path through the next product proofs.
Work may overlap when interfaces are stable, but Atlas does not claim a later
proof until its prerequisites have been demonstrated.

| Order | Proof | Exit evidence | State |
| --- | --- | --- | --- |
| 1 | Cloud existing-client dogfood | Herdr enters both declared development environments on a persistent DigitalOcean lab host, observes their distinct non-secret configuration, operates one shared durable checkout, survives reboot, and demonstrates reset of environment-local drift without losing owner work | complete |
| 2 | Private environment networking | Two environments bind the same loopback port; neither reaches the other environment, host loopback, tailnet, LAN, or cloud metadata endpoints without policy; intended public egress still works | in progress |
| 3 | Paired operator control | A controller device is explicitly paired, receives a revocable identity, and can inspect, reset, and snapshot environments over a private transport; tailnet membership alone grants no Atlas authority | queued |
| 4 | Private route | One explicitly selected environment port is reachable from an authorized paired device without a public listener or arbitrary upstream target | queued |
| 5 | Authenticated browser surface | An agent operates one isolated browser identity while the operator can observe, take over, return control, and revoke access | queued |
| 6 | Narrow grant | One source credential remains outside the environment while a broker performs a bounded operation or issues a short-lived derivative | queued |
| 7 | Physical alpha | A selected x86 machine installs encrypted persistent Atlas state with one declared unlock mode and protected host recovery capacity, enrolls privately, exposes automatic durable owner storage to the default environment, and survives reboot and reset without losing owner data | deferred pending hardware |
| 8 | Runtime environment definitions | The control plane creates, inspects, resets, and deletes definitions and instances without weakening peer-derived identity or storage guarantees | later |
| 9 | Portable environment declaration | A backend-independent, non-secret seed maps to the definition model; import requires explicit operator or client action and has no imperative setup hook | later |
| 10 | Host-base comparison | The same proven behavior is ported to a bootc/OCI host and compared with the NixOS adapter on installation, update, rollback, recovery, and complexity | later |

### Parallel storage hardening

The installed-layout KVM proof is sufficient to continue hardening storage in
parallel with proofs 1–5, but it is not physical evidence. Supported update and
recovery, power-loss and metadata-exhaustion testing, and backup and restore are
required before Atlas is treated as broadly operable. Optional quotas for
additional environments are a later policy unless real multi-environment use
makes them necessary sooner.

## Current spike gaps

The NixOS adapter is evidence for lifecycle, identity, reset, volume separation,
reboot-persistent machine state, copy-on-write root recovery, and an x86
KVM-installed encrypted storage layout. Physical installation, the human unlock
ceremony, and hardware recovery remain unproven.

- The DigitalOcean profile is a replaceable remote laboratory. It composes the
  same Atlas host with a separately attached Btrfs data volume, reports
  provider-managed rather than owner-controlled encryption, and reserves the
  root disk for host recovery. Its temporary key-only OpenSSH bootstrap is an
  explicit degraded state that must be replaced by Tailscale SSH after
  enrollment. Configuration evaluation is not live deployment evidence.

- Persistent development and contract-test VMs mount a dedicated Btrfs data disk
  at `/var/lib/atlas`. Environment roots, applied seeds, named root snapshots,
  and durable volumes are separate subvolumes with no default per-environment
  quota.
- The live ISO retains the directory adapter and truthfully reports snapshots
  and rollback as unavailable.
- The parameterized installed-storage module places the host and Atlas data in
  one LUKS2 container, with a fixed host logical volume and an elastic Btrfs data
  logical volume. It requires installer-generated device UUIDs rather than
  trusting reusable labels. KVM proves one fully instantiated installation,
  unattended test-key boot, reboot, reset, durable owner-home survival, and
  declared-volume survival. The live
  ISO still does not install this layout, and the operator-passphrase ceremony,
  physical hardware, power-loss, recovery, and metadata-exhaustion behavior are
  untested.
- The current implementation enters as the configured human-owner UID at
  `/home/<owner>` with passwordless environment-local `sudo`. This deliberately
  grants every admitted process root inside that environment, not Atlas-host
  root; narrower per-process authority remains future Grant work.
- The current systemd-nspawn adapter still shares host networking. The selected
  Incus substrate has demonstrated separate loopback and network namespaces plus
  fail-closed egress policy in a disposable KVM proof, but the Atlas Environment
  Entry adapter does not own that behavior yet.
- The read-only host Nix store remains visible inside environments for declared
  tools.
- There is no route proxy, browser service, grant broker, persistent installer,
  paired-device authority, or encrypted recovery path yet.

## Product questions still open

- How much fixed host capacity should the first hardware profile reserve, how
  should it recover when the elastic Btrfs data filesystem is full, and which
  optional quota policy is acceptable for additional environments?
- When does a higher-risk environment require a microVM rather than the selected
  unprivileged Incus container backend?
- Which browser automation capability can preserve the stated cookie and
  controller boundaries?
- Which credential protocols support useful brokered authority without exposing
  reusable source credentials?
- Which guarantees require owning the full image, and which can honestly be
  offered by a supported installation on an existing Linux host?
