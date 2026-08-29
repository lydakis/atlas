# Persistent Storage v0

Status: elastic Btrfs roots, applied seeds, root snapshots, restore, reboot,
reset, generation switch, and rollback validated in QEMU; encrypted physical
storage, protected recovery capacity, and automatic durable-home policy remain
unproven

## Outcome

An Atlas environment is a reusable Linux machine context, not an agent, task,
project, or session. Several agents or human-operated clients may concurrently
enter the same environment and share its OS state, processes, services, and
attached data.

The default environment is intended to feel like the machine. Its resettable
root therefore grows with the filesystem that contains the Atlas data root. It
does not receive an arbitrary fixed-size quota. Packages, `/etc`, caches, and
the resettable portions of the current prototype home survive disconnect,
environment restart, host reboot, and a supported NixOS generation change. They
disappear only after an explicit environment reset.

Durable volumes are composed into that ordinary Linux tree at declared mount
points. They retain a lifecycle separate from the resettable root, so reset can
replace the environment OS without deleting repositories, uncommitted work, or
artifacts stored on those volumes.

## Storage shape

The persistent VM uses a dedicated Btrfs data filesystem. Each declared
environment receives sibling subvolumes and host-only lifecycle metadata:

```text
/var/lib/atlas/environments/<environment-id>
├── seed                    read-only applied seed
├── rootfs                  writable snapshot used by nspawn
├── rootfs.ready            host-only readiness marker
└── snapshots
    └── <snapshot-name>     read-only operator snapshot

/var/lib/atlas/volumes/<volume-id>/data
                             writable durable-data subvolume
```

The seed is produced by the privileged host launcher from the pinned base and
current host-managed environment bootstrap, marked read-only, and never mounted
inside the environment. Its identity includes a digest of the exact bootstrap
recipe, so changing that recipe invalidates and rebuilds the applied seed even
when the base image and systemd package are unchanged. The writable root is a
copy-on-write snapshot of that seed. Atlas prepares replacement roots under
private sibling names and publishes them with same-filesystem renames. This
preserves atomic publication and detachment without a loop device or fixed-size
nested filesystem.

Seed extraction runs through the root-only lifecycle service because a normal
Ubuntu root contains non-root ownership and setuid or setgid system binaries.
That service receives the ownership, mode-preservation, and Btrfs capabilities
needed for this operation, while `ProtectSystem=strict` and `ReadWritePaths`
confine its writable filesystem view to environment state and lifecycle locks.
The public inspection service retains `RestrictSUIDSGID=true` and cannot invoke
seed preparation or any lifecycle operation.

The directory adapter remains available for the non-persistent live ISO. It
reports copy-on-write snapshots and rollback as unavailable.

The adapter deliberately has no `runtimeSize` setting. The root shares
the available capacity and failure domain of the filesystem containing
`/var/lib/atlas`. Filesystem isolation comes from the nspawn root, user
namespace, explicit binds, and process boundary. Resettable describes lifecycle,
not size.

## Composed durable data

The complete environment view is the resettable Linux root plus durable volumes
mounted inside it:

```text
environment
├── resettable OS state
│   ├── packages and package database
│   ├── /etc
│   ├── caches and temporary build state
│   └── environment-local home paths
│       ├── ~/.config
│       ├── ~/.cache
│       ├── ~/.local/bin
│       └── ~/.local/state
└── durable volume mounts
    ├── /home/<owner>
    │   ├── repositories and uncommitted work
    │   ├── retained artifacts
    │   ├── ~/.local/share
    │   └── other ordinary owner files
    └── other explicitly attached volumes
```

Atlas automatically creates the configured owner's home volume. Environments
request access to it independently of other declared volumes. The current proof
also mounts a separate `projects` volume at `/home/owner/Projects`, showing that
a conventional home may contain nested volumes with different attachment
policy.

Agents are processes, not storage owners. Attaching a volume to a second
environment exposes the same human-owned data there without copying it. Atlas
does not create a new environment or volume for every agent.

## Owner account and home composition

Entry runs as the configured human-owner account at `/home/<owner>`. It has
passwordless environment-local `sudo`: every admitted process can become root
inside that environment, but the user namespace does not turn that into host
root. Agents remain programs sharing the owner's environment authority, not
Unix identities.

The durable home is the simple default for ordinary files. Atlas mounts four
paths from the resettable root over it: `~/.config`, `~/.cache`,
`~/.local/bin`, and `~/.local/state`. `~/.local/share` remains durable in v0.
This gives different environments separate tool configuration while preserving
the same repositories and documents. Atlas does not infer lifecycle from file
names: dotfiles outside the explicit list remain durable.

Atlas prepares only the declared mountpoint paths below the durable home. The
host helper anchors itself to an open owner-home directory and walks each path
with descriptor-relative `mkdirat` and `openat` operations that refuse symbolic
links. Owner-controlled pathnames therefore cannot redirect privileged
preparation into another host location.

## Reset

The reset operation is the destructive lifecycle action for resettable state.
It:

1. takes the environment lifecycle lock
2. validates that the managed state parent, root, and readiness marker are not
   symlinks or unexpected file types
3. fingerprints the durable owner-home device and inode when one is attached
4. stops the complete environment service and active entry workload
5. confirms the service is inactive
6. refuses reset while mounts remain below the environment root
7. removes abandoned private bootstrap or deletion directories
8. realizes the current declared seed when its pinned identity is missing or
   stale, then verifies the expected identity before touching the active root
9. creates a writable snapshot from the read-only applied seed
10. atomically swaps that snapshot into the active root path and publishes the
    current owner-layout identity in a host-owned sidecar
11. recursively removes the detached old-root subvolume, or leaves a private tombstone for
   later cleanup if deletion fails
12. verifies the durable owner-home fingerprint is unchanged and reports that
    observed result

Reset returns immediately to an initialized root rather than re-extracting the
base image. Because the root and seed remain below `/var/lib/atlas`, reset
behaves the same way before and after host reboot.

## Root snapshots and restore

The root-only lifecycle socket exposes four bounded operations:

```text
atlas environment snapshot create <environment> <snapshot>
atlas environment snapshot list <environment>
atlas environment snapshot restore <environment> <snapshot>
atlas environment snapshot delete <environment> <snapshot>
```

Create briefly stops an active environment, takes a read-only Btrfs snapshot of
its root, and restarts it. Restore takes a writable snapshot of the selected
root snapshot, atomically replaces the active root, and restarts an environment
that was previously running. Snapshot names are bounded lowercase slugs, and
all snapshot paths are derived from the environment's opaque identity.
Create and restore require the current host-owned owner-layout marker, and
restore rejects a snapshot whose in-root compatibility marker predates the
current layout. Atlas reads that in-root marker through descriptor-relative,
no-follow traversal, so a mutable root cannot make an external host marker
stand in for snapshot compatibility through a symbolic link.

These operations snapshot resettable machine state only. Attached volumes are
sibling subvolumes and are deliberately outside the root snapshot. Volume
snapshots, backup, and recovery from owner-data deletion remain separate work.

A root snapshot is a convenience checkpoint, not a trusted recovery floor. It
may preserve compromised or simply broken state. Reset always reconstructs from
the host-only applied seed; restoring a snapshot never promotes that snapshot
into the seed.

Btrfs snapshots are non-recursive. An environment can create a nested Btrfs
subvolume inside its writable root, but silently omitting that data from a root
snapshot would violate the checkpoint contract. Atlas therefore refuses root
snapshot creation while nested subvolumes exist. Reset still works: lifecycle
deletion recursively removes the root and every nested subvolume before the
fresh seed snapshot is published. Durable data belongs in attached sibling
volumes, not nested subvolumes created inside the resettable root.

## Capacity and recovery reserve

The Btrfs adapter is elastic and unbounded per environment. This is
the right default for one primary environment on a dedicated machine, but it is
not a complete resource-exhaustion defense. One environment can consume the
filesystem shared by other environments and Atlas data.

The physical installer must preserve enough independent host capacity for the
control plane, updates, diagnostics, and recovery. That guarantee should come
from the installed storage layout or filesystem reservation, not a tiny quota
on the primary environment. Atlas does not currently claim that reserve.

Optional per-environment quotas remain useful policy for secondary or
less-trusted environments. They are not the default environment contract.

## Stable host-managed runtime

The Ubuntu root uses a stable in-environment `/sbin/init` target and a writable
base-unit symlink farm. The current host systemd package is mounted read-only at
the stable target on each service start. Untouched base units follow that bind,
while packages installed inside the environment may replace individual links
with environment-owned units. Persistent host-managed state therefore does not
retain a generation-specific Nix store path that can disappear after a later
update and garbage collection.

## Encryption and backup boundary

Copy-on-write root reconstruction and operator snapshots are implemented. They
do not provide backup, snapshot durable volumes, or protect writable owner data
from an authorized environment. At-rest encryption also remains `none` and
degraded. The physical proof must place `/var/lib/atlas` on encrypted storage
with a real unlock and recovery policy.

## Proven in QEMU

The AArch64 host-contract test verifies that:

- `/var/lib/atlas` is a dedicated Btrfs filesystem in the test VM
- environment roots and durable volumes are Btrfs subvolumes rather than
  fixed-size nested images
- each initialized environment has a read-only applied seed and writable
  copy-on-write root
- package, `/etc`, and ordinary home mutations survive host reboot
- `/run`, process memory, and live services are reconstructed after reboot
- reset before the first post-reboot entry removes the intended root
- active-workload reset removes resettable state and preserves the volume
- reset reconstructs the root from the applied seed without re-extracting the
  base image
- reset reconstructs an absent root and repairs a missing readiness marker
- reset repairs a missing or stale applied seed before replacing the active
  root and refuses a seed whose realized identity does not match the current
  declaration
- a named read-only root snapshot survives reboot, can be listed and restored,
  and can be deleted explicitly
- restoring a root snapshot removes later root changes while preserving later
  durable-volume changes
- snapshot compatibility validation refuses symbolic links at every component
  of the in-root owner-layout marker path
- interrupted root and seed bootstrap subvolumes are recursively removed during
  entry and reset
- root snapshot creation rejects nested Btrfs subvolumes instead of silently
  omitting their contents, while reset recursively removes them
- symlinks at the managed root are rejected without touching their targets
- the stable init and base-unit targets work across generation switch and
  rollback
- resettable machine state and durable-volume state survive generation switch
  and rollback on a reboot-persistent host

The test does not prove a host recovery reserve, disk encryption, durable-volume
snapshots, backup, sudden-power-loss recovery, optional quotas, or
physical-hardware compatibility.

## Remaining exit evidence

Persistent physical storage remains in progress until Atlas has:

1. a persistent installer or disk image rather than a live ISO
2. encrypted `/var/lib/atlas` storage with a real unlock and recovery policy
3. an installed storage layout that preserves host control and recovery
   capacity when environment data grows
4. an automatic durable user-storage attachment for the default environment
5. optional quota policy for additional environments and other mutable state
6. durable-volume snapshot, backup, and restore policy
7. full-filesystem, metadata-exhaustion, power-loss, and recovery tests
8. the same lifecycle story on representative physical hardware
