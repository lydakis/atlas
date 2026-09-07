# Persistent Storage v0

Status: Incus Btrfs roots, instance snapshots, reset, durable owner-home and
declared-volume preservation validated in x86 KVM; physical storage recovery,
quotas, and durable-data backup remain unproven

## Outcome

An Atlas environment is a reusable Linux machine context, not an agent, task,
project, or session. Several agents or human-operated clients may enter the same
environment and share its mutable OS state and attached data.

The default environment is intended to feel like the machine. Its root grows
with the Incus storage pool rather than receiving an arbitrary fixed-size
filesystem. Packages, `/etc`, caches, and resettable home paths survive client
disconnect and instance restart. They disappear only after explicit reset.

Durable volumes are composed into that ordinary Linux tree at declared mount
points. They retain a lifecycle separate from the Incus instance, so reset can
replace the environment OS without deleting repositories, uncommitted work, or
ordinary owner files.

## Storage shape

The persistent VM uses a dedicated Btrfs data filesystem:

```text
/var/lib/atlas/incus-pool
└── Incus-managed instance and dependent-volume subvolumes

/var/lib/atlas/volumes/<volume-id>/data
└── Atlas-managed durable owner or declared volume
```

Incus owns the internal names and layout of environment roots. Atlas refers to
an environment by its declared instance name and does not manipulate Incus
subvolumes directly.

Each environment that receives the durable owner home also receives dependent
Incus volumes for `~/.config`, `~/.cache`, `~/.local/bin`, and
`~/.local/state`. Those dependent volumes follow the instance snapshot and
delete lifecycle. The durable owner home and explicitly declared volumes are
shifted host-path disk devices. They remain outside instance snapshots and
survive instance deletion.

The Incus Btrfs pool is copy-on-write and shares the available capacity of the
Atlas data filesystem. The live ISO uses an Incus directory pool and reports
snapshot and rollback support as unavailable until that adapter is separately
qualified.

## Composed durable data

```text
environment instance
├── resettable OS state
│   ├── installed packages and package database
│   ├── /etc
│   └── resettable owner paths
│       ├── ~/.config
│       ├── ~/.cache
│       ├── ~/.local/bin
│       └── ~/.local/state
└── durable disk devices
    ├── /home/<owner>
    │   ├── repositories and uncommitted work
    │   ├── documents and retained artifacts
    │   ├── ~/.local/share
    │   └── other ordinary owner files
    └── other explicitly attached volumes
```

Atlas automatically creates the configured owner's home volume. Environments
request access to it independently of other volumes. The current proof also
mounts a separate `projects` volume at `/home/owner/Projects`, showing that a
conventional home may contain nested volumes with different attachment policy.

Agents are processes, not storage owners. Attaching a volume to a second
environment exposes the same human-owned data there without creating a new
environment or copying the data.

## Owner account and mountpoint safety

Entry runs as the configured human-owner account at `/home/<owner>` with
passwordless environment-local `sudo`. An admitted process can become root
inside its container but does not receive Atlas-host root or the Incus
administrative socket.

Atlas prepares only declared paths below the durable owner home. The host helper
anchors itself to an open owner-home directory and walks each component with
descriptor-relative, no-follow operations. Owner-controlled pathnames therefore
cannot redirect privileged preparation into another host location.

## Reset

The root-only reset operation:

1. validates the declared Incus backend, environment identity, exact instance
   name, and canonical trusted Nix-store reconcile command
2. takes the environment lifecycle lock and passes that same open lock into
   instance reconciliation; a reconciler takes the per-environment lock before
   the global Incus mutation lock, so system activation, entry, reset, and
   snapshots cannot mutate one environment concurrently
3. refuses reset while named instance snapshots exist, leaving their explicit
   deletion to the operator
4. fingerprints the durable owner-home and every declared volume by Btrfs
   subvolume UUID on the primary adapter, with host device and inode as the
   non-Btrfs fallback; inability to read an expected Btrfs identity fails closed
5. deletes the existing instance and its dependent resettable volumes
6. recreates the instance from the pinned Ubuntu system image
7. reapplies the isolated ID map, network ACL, read-only host surfaces, owner
   home, declared volumes, and dependent resettable paths
8. provisions the conventional owner and environment-local sudo policy
9. verifies that no durable owner-home or declared-volume fingerprint changed

All Incus commands are forced to the local daemon. Atlas does not consult
ambient Incus remote configuration. The administrative socket remains
host-only.

Host activation also inventories Atlas-marked instances. An instance omitted
from the active declaration is stopped and has autostart disabled while its
root, dependent storage, and named snapshots remain available for explicit
operator recovery or deletion.

## Instance snapshots and restore

The root-only lifecycle socket exposes:

```text
atlas environment snapshot create <environment> <snapshot>
atlas environment snapshot list <environment>
atlas environment snapshot restore <environment> <snapshot>
atlas environment snapshot delete <environment> <snapshot>
```

These are Incus instance snapshots. On the Btrfs adapter they cover the
instance root and dependent resettable volumes. They deliberately exclude the
durable owner home and declared host-path volumes. Restore therefore rolls back
installed packages, `/etc`, and resettable home configuration while preserving
later writes to durable data.

Snapshot names are bounded lowercase slugs, all instance identities come from
the declared contract, and the management service converts Incus failures into
a stable redacted protocol error while retaining bounded diagnostics in the
host journal. Before restore, Atlas verifies the snapshot's host-owned layout
identity, empty profile set, complete local and expanded device configuration,
and allowed effective configuration against the active declaration. Any mismatch
returns `reset_required` without applying the snapshot's older configuration or
device attachments.

Because Incus snapshots belong to their instance, deleting that instance would
also delete every named checkpoint. Atlas therefore returns `conflict` from
reset while any named snapshot exists. The operator must explicitly delete the
snapshots before resetting the environment.

The same durable-volume fingerprints are verified across snapshot restore.
`preservedVolumes` is returned only after those checks succeed.

An instance snapshot is a convenience checkpoint, not a trusted recovery
floor. It may preserve compromised state. After any named snapshots have been
explicitly deleted, reset always recreates the instance from the pinned image
rather than promoting a snapshot into a base.

## Capacity, encryption, and backup

The Btrfs pool is elastic and unbounded per environment. This is the right
default for one primary environment on a dedicated machine, but it is not a
complete resource-exhaustion defense. One environment can consume space needed
by other environments or Atlas data.

The installed-layout KVM proof places Atlas state in LUKS2 and reserves fixed
host capacity outside the elastic data volume. A real operator unlock ceremony,
physical recovery, power-loss behavior, metadata exhaustion, optional
per-environment quotas, and durable-volume backup and restore remain open.

## Runtime evidence

`nixos/tests/host-contract.nix` proves on x86 KVM that:

- Ubuntu package installation and `/etc` mutation persist across instance
  restart and remain isolated from another environment
- owner files and a declared project volume are shared only with environments
  that receive those devices
- snapshot restore rolls back root and resettable home changes while preserving
  later durable writes
- explicit reset removes package, root, and resettable-home drift while
  preserving the durable owner-home inode and declared-volume contents
- restarting the Incus daemon leaves the running instance and durable data
  intact

These tests prove the adapter behavior in a VM. They do not substitute for
physical storage and recovery evidence.
