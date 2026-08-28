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

## Persistence vocabulary

Atlas distinguishes three lifecycle classes.

### Durable data

Operator-owned volumes contain repositories, worktrees, datasets, and artifacts
that must survive environment reset. Their documented policy may additionally
cover update, recovery, backup, and machine loss. Durability is an explicit
promise, not a consequence of a path happening to be on disk.

### Resettable machine state

The environment root contains installed packages, `/etc`, caches, tool
configuration, and any home content not placed on durable owner storage. The
product default is disk-backed and persistent until the operator deliberately
resets or deletes the environment. It survives disconnect, process failure,
host reboot, and supported update, but it is not implicitly backed up and is
not protected from explicit reset.

The exact owner-home composition remains open. Atlas may make the entire owner
home durable or mount selected durable directories inside a resettable home.
Either choice must look conventional inside the environment and state clearly
what reset removes. `/home/agent` is only the current mapped-root spike path.

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

## Ordered product proofs

| Order | Proof | Exit evidence | State |
| --- | --- | --- | --- |
| 1 | Persistent physical storage | An elastic disk-backed resettable root and automatically attached encrypted owner storage survive reboot and supported update; reset preserves owner data; storage layout protects host recovery capacity | in progress |
| 2 | Private environment networking | Two environments bind the same loopback port; neither reaches the other environment, host loopback, tailnet, LAN, or metadata endpoints without policy; intended public egress still works | queued |
| 3 | Private route | One explicitly selected environment port is reachable from an authorized paired device without a public listener or arbitrary upstream target | queued |
| 4 | Authenticated browser surface | An agent operates one isolated browser identity while the operator can observe, take over, return control, and revoke access | queued |
| 5 | Narrow grant | One source credential remains outside the environment while a broker performs a bounded operation or issues a short-lived derivative | queued |
| 6 | Existing-client dogfood | Herdr or Codex uses the complete flow on representative physical hardware without adopting an Atlas project, task, or conversation model | queued |
| 7 | Runtime environment definitions | The control plane creates, inspects, resets, and deletes definitions and instances without weakening peer-derived identity or storage guarantees | later |
| 8 | Portable environment declaration | A backend-independent, non-secret seed maps to the definition model; import requires explicit operator or client action and has no imperative setup hook | later |
| 9 | Host-base comparison | The same proven behavior is ported to a bootc/OCI host and compared with the NixOS adapter on installation, update, rollback, recovery, and complexity | later |

## Current spike gaps

The NixOS adapter is evidence for lifecycle, identity, reset, volume separation,
reboot-persistent machine state, and copy-on-write root recovery. The first
physical adapter target is Btrfs, but encryption, installed-disk layout, and
hardware recovery remain unproven.

- Persistent development and contract-test VMs mount a dedicated Btrfs data disk
  at `/var/lib/atlas`. Environment roots, applied seeds, named root snapshots,
  and durable volumes are separate subvolumes with no default per-environment
  quota.
- The live ISO retains the directory adapter and truthfully reports snapshots
  and rollback as unavailable.
- The physical image remains a live ISO. `/var/lib/atlas` is not encrypted,
  host recovery capacity is not protected, primary durable owner storage is not
  created automatically, and power-loss and recovery behavior are untested.
- `/home/agent` remains a spike convention for mapped root, not the product
  identity. The owner account, conventional home layout, and environment-local
  elevation contract remain open.
- Environments currently share host networking. Isolation and duplicate port
  use are not yet provided by the Environment Entry adapter.
- The read-only host Nix store remains visible inside environments for declared
  tools.
- There is no route proxy, browser service, grant broker, persistent installer,
  or encrypted recovery path yet.

## Product questions still open

- Which encrypted installed-disk layout best protects host recovery capacity
  when the elastic Btrfs data filesystem is full, and which optional quota
  policy is acceptable for additional environments?
- How should the human owner account, conventional home, and environment-local
  elevation work without turning agents into identities?
- Which environment backend is sufficient for the first trust model, and when
  does a higher-risk environment require a microVM?
- Which browser automation capability can preserve the stated cookie and
  controller boundaries?
- Which credential protocols support useful brokered authority without exposing
  reusable source credentials?
- Which guarantees require owning the full image, and which can honestly be
  offered by a supported installation on an existing Linux host?
