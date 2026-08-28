# Environment Entry v0

Status: persistent-service, reboot-persistent resettable root, and durable-volume
adapter validated in QEMU

## Outcome

A human owner or an existing agent client enters a named Atlas environment
through an ordinary remote Linux workflow. It sees normal Linux, may install
packages and mutate the environment with environment-local administrative
authority, and works on repositories mounted from explicit durable volumes.
Atlas derives the caller's environment from the authenticated entry boundary
and kernel state, never from a project, agent, task, or caller-supplied
identifier.

The central lifecycle rule is:

> Humans own durable data. Environments own resettable machine state. Live
> execution is volatile. Atlas composes them into ordinary Linux at entry time.

## Model

### Environment definition

An environment definition describes one execution and authority context. It
contains:

- ordered non-secret configuration layers
- aliased tool packages and managed non-secret Git configuration
- instance-level package, Git, and variable overrides
- volume attachments with target paths and access modes
- resource and network policy

Definitions may eventually be saved or composed at runtime. In the current
adapter they are declarative NixOS configuration.

### Configuration layer

A layer is reusable non-secret configuration. Layers compose from left to
right. Later package aliases replace earlier aliases, Git configuration merges
recursively, and later variables replace earlier variables. Instance values
then override every layer. Duplicate layers and unknown layers are rejected.
Atlas-reserved keys, including the `ATLAS_` prefix and runtime-owned
`GIT_CONFIG_SYSTEM`, `HOME`, `LOGNAME`, `PATH`, `SHELL`, and `USER`, cannot be
supplied by a layer or instance.

A layer is convenience, not a trust boundary. Two environments created from the
same layer do not share identity, mutable OS state, processes, or grants.

### Environment instance

An environment instance is the mutable realization of a definition. It has:

- an opaque Atlas identity independent of its human-readable name
- a kernel-enforced principal and cgroup boundary
- a resettable root filesystem and home
- a process and resource-accounting scope
- an effective non-secret configuration snapshot
- declared network behavior
- references to volumes, grants, surfaces, routes, and activity

The instance is reusable across entries and resettable over its lifecycle.
Installed packages, caches, `$HOME`, and root-filesystem changes survive an SSH
disconnect, environment restart, host reboot, and supported update.
`atlas environment reset <name>` terminates the instance and deliberately
destroys those changes. The Btrfs adapter publishes a fresh root from its
declared seed before reset returns; the volatile directory adapter recreates
the root on the next entry.

Resettable does not mean recreated for every connection or reboot. It means the
operator can deliberately throw the machine state away without losing data
declared durable.

### Volatile execution state

Process memory, kernel process state, open file descriptors, network
connections, transient sockets, locks, PID files, mount state, and `/run` do not
survive a normal reboot. Declared services may restart from persistent files,
but Atlas does not transparently resume arbitrary processes, connections, or
client-owned terminal state.

Agents should not need special paths to keep ordinary files across reboot.
Installed packages, `/etc`, home configuration, caches, and other normal root
filesystem contents belong to resettable machine state. Conventional temporary
locations may be cleared only under an explicit, discoverable policy.

### Volume

A volume is durable operator-owned data with its own identity and lifecycle. An
environment definition attaches it at an explicit absolute path, read-write or
read-only. Repositories, worktrees, datasets, and artifacts that must survive
environment replacement belong on a volume.

An environment does not own an attached volume. Resetting or deleting its
instance must not delete volume contents. Multiple cooperating environments may
mount the same volume deliberately. An environment without that mount must not
be able to reach it through its filesystem.

The current spike mounts one `projects` volume at `/home/agent/work` in
`shared-dev` and `personal-dev`. `restricted` receives no project volume.
`/home/agent` is a temporary adapter convention, not an agent identity or the
settled product home. The intended product account belongs to the human owner,
and durable mounts should appear at conventional paths inside that owner's
normal environment view.

### Entry

An entry is the authenticated transition that starts a process inside an
environment. A remote adapter may map an SSH login to one fixed environment. A
local adapter may expose the same transition to an operator or compatible
client. The entry adapter selects no project and accepts no environment
identifier as proof of authority.

Every process started through an entry receives:

- `ATLAS_ENVIRONMENT_ID`
- `ATLAS_ENVIRONMENT_NAME`
- `ATLAS_CONTROL_SOCKET`
- a conventional Linux `HOME`, shell, working directory, and base PATH
- declared Nix tool closures appended to PATH in the current adapter
- a managed system-level Git configuration
- the effective non-secret variables in the environment definition
- only the volumes attached by its definition

The in-environment user is mapped root in v0 so a client can use ordinary Ubuntu
tools such as `apt` and mutate the resettable filesystem. The launcher sets its
prototype home to `/home/agent`. Neither the account nor the path means one
agent owns the environment: several human or agent-driven processes may share
it. User namespaces map that identity away from host root. The owner-account,
home-layout, and environment-local elevation contract remain open before a
persistent installation. This is a prototype isolation mechanism, not a claim
that every possible container escape has been excluded.

## Projects, repositories, and agents

Atlas does not assign an environment to a project. The client or operator
chooses an environment and volume attachment when starting work. Project,
repository, agent, task, and conversation labels may be recorded as untrusted
attribution, but they do not grant entry, a mount, or authority.

An agent is a program, not a Linux identity or an owner of an environment.
Codex, Claude Code, Herdr workers, shell processes, and a human login may all
operate in the same environment. When they run under one environment account,
Unix permissions do not isolate them from each other. A separate environment
or a future narrower process grant is required when that isolation matters.

A repository is ordinary data on a volume. Clients clone, copy, and create
worktrees with their normal tools. Atlas requires no repository registration
step and owns no coding session abstraction.

Several agents may enter one environment and share its mutable execution state.
Several environments may mount one project volume and share its files without
sharing installed packages, `$HOME`, or `/etc`. Atlas does not serialize Git
operations or make concurrent writes safe. Operators and agent tools still own
that coordination.

Separate environments are warranted when agents need different credentials,
network policy, installed dependencies, reset policy, or resource limits.
They are not required merely because two agents work on the same repository.
One default environment is the intended normal experience; another environment
is an explicit boundary, not routine project setup.

## Variables and credentials

Environment variables in a definition are non-secret. In the declarative NixOS
adapter their values may enter the Nix store and world-readable system
configuration. Managed Git configuration follows the same rule.

Names, email addresses, default branches, aliases, and similar Git settings may
be composed in layers. The generated system file is immutable. Mutable global
Git configuration lives in the resettable environment home and is removed by
reset. If a config file must be durable, the operator may deliberately place it
on a volume and link or include it, accepting the shared-data semantics.

SSH keys, signing keys, GitHub tokens, credential helpers containing secrets,
and other authentication material are grants, not environment configuration.
A future materialized-secret grant may add a value to one process, but it must
be reported as degraded and must not place a secret in a definition, layer, or
Nix derivation.

## Local control interface

Atlas exposes two versioned Unix-domain sockets. The public socket supports
read-only discovery and inspection. A separate mode-`0600` management socket
supports lifecycle mutation. Both authenticate the kernel-observed peer. The
service derives an environment from the peer UID or an anchored cgroup prefix;
unknown identities fail closed, and a descendant cgroup merely named after a
different environment cannot forge identity. Caller-authored labels do not
establish authority.

The implemented interface is:

```text
atlas doctor --json
atlas environment list --json
atlas environment inspect self --json
atlas environment inspect <name> --json
atlas environment reset <name> --json
atlas environment snapshot create <name> <snapshot> --json
atlas environment snapshot list <name> --json
atlas environment snapshot restore <name> <snapshot> --json
atlas environment snapshot delete <name> <snapshot> --json
```

Listing and inspection expose only non-secret configuration. Reset is an
operator action and is rejected from inside an environment, even when the
caller is root inside that environment. Snapshot operations share the root-only
lifecycle socket and are not exposed by the public inspection socket.

## Initial NixOS adapter

The adapter currently:

- pins Canonical's Ubuntu Noble 24.04 OCI root filesystem for both supported
  architectures
- creates one atomically prepared resettable root at
  `/var/lib/atlas/environments/<id>/rootfs`, with readiness metadata beside it
- stores a read-only applied seed beside each root and realizes the active root
  as a writable Btrfs snapshot
- validates and, when necessary, rebuilds that seed against the current pinned
  declaration before entry or reset can use it
- creates, lists, restores, and deletes named read-only root snapshots through
  the operator-only lifecycle surface
- lets that root grow elastically on the Atlas data filesystem, with no default
  per-environment quota
- stores volume data under `/var/lib/atlas/volumes/<id>/data`
- maps each fixed Tailscale SSH login to one environment launcher
- supervises one persistent `systemd-nspawn` service per environment with a
  user namespace
- joins each entry to that service's namespaces and delegated session cgroup
- idmaps only explicitly attached volumes into the container
- mounts the Atlas contract and local control socket
- appends declared Nix tool closures to the ordinary Ubuntu PATH
- supplies the environment's init and untouched base units through a stable
  read-only host-systemd bind rather than persisting generation-specific
  Nix-store paths
- derives self identity from the environment service's anchored cgroup tree
- exposes reset only through a separate root-only management socket
- serializes lifecycle changes and atomically replaces the resettable root only
  after the service is confirmed stopped
- reloads generated environment configuration on NixOS generation changes

The persistent VM places `/var/lib/atlas` on a dedicated Btrfs filesystem. Each
root is a subvolume that shares the filesystem's available capacity and has no
arbitrary 1 GiB ceiling. Live process and mount state are reconstructed after
host reboot, while installed packages, `/etc`, ordinary home files, and caches
remain until explicit reset. Volumes are sibling Btrfs subvolumes composed into
the environment at their declared paths, so root reset and restore do not
include them. The spike does not yet reserve host recovery capacity, enforce
optional quotas, encrypt persistent storage, or snapshot durable data, so those
capabilities are reported as degraded or absent. Network isolation is still
shared-host and reported as degraded. The read-only host Nix store remains
visible so declared tools can execute and is reported as degraded tool
isolation.

Entries reuse one persistent nspawn instance. Several clients can enter it at
once and share its mutable OS state. Their processes live under the environment
service's cgroup, so stopping or resetting the instance includes active entries.
Atlas does not yet provide a durable task abstraction or reconnect arbitrary
client-owned PTYs after their client exits.

This adapter proves the lifecycle and identity seam. It does not settle the
eventual runtime manager, container backend, or base distribution.

## Acceptance story

1. The owner declares a durable `projects` volume and three environments.
2. `shared-dev` and `personal-dev` mount it at `/home/agent/work`; `restricted`
   does not.
3. An existing SSH-compatible client enters `shared-dev`, clones a repository
   onto the volume, and commits with its managed Git identity.
4. `personal-dev` sees the repository through the same volume but retains a
   different `/etc`, `$HOME`, installed tool set, and Git identity.
5. A human or agent-driven process installs a Debian package and changes `/etc`
   with environment-local administrative authority in
   `shared-dev`. Neither change appears in `personal-dev`.
6. A second client concurrently enters the same `shared-dev` instance and sees
   its state.
7. The host reboots. Its package, `/etc` change, and home remain; live process
   state and `/run` do not. The repository on the volume also remains.
8. The operator snapshots `shared-dev`, makes another root change, and restores
   the snapshot. The later root change disappears while later volume data
   remains.
9. The operator resets `shared-dev` while a workload is active. Its package,
   process tree, `/etc` change, and resettable home disappear; the repository
   on the volume remains.
10. `restricted` cannot see the project volume and cannot reset another
   environment.
11. New resettable state and the durable repository survive control-service
    restart and NixOS generation switch and rollback.

## Proven in the QEMU contract

The AArch64 integration test proves:

- deterministic layer, package, Git, and variable composition
- evaluation failure for invalid names, IDs, UIDs, variables, volumes, and
  mount targets
- fixed interactive and non-interactive entry into named environments
- peer-derived environment identity with non-environment callers failing closed
- a mapped root user can mutate the environment without mutating host `/etc`
- a local Debian package installs and persists across sequential entries and
  host reboot
- `/etc` and ordinary home changes persist across host reboot
- `/run` and live environment processes remain volatile across host reboot
- `/var/lib/atlas` is a dedicated Btrfs filesystem in the VM; each resettable
  root and durable volume is a subvolume with no fixed-size image or default
  per-environment quota
- each initialized environment has a read-only applied seed and writable
  copy-on-write root
- reset refreshes a stale applied seed before reconstructing the root
- reset reconstructs an absent Btrfs root and repairs a missing readiness marker
- a symbolic link or non-directory at a managed root fails closed, and
  interrupted root and seed bootstrap subvolumes are recursively cleaned
  without following links
- simultaneous clients enter one persistent environment instance
- package and filesystem mutations do not appear in a neighboring environment
- an active workload is anchored beneath the environment service cgroup
- reset stops the active workload and atomically removes installed tools,
  resettable home, and root-filesystem changes
- reset preserves the attached project volume
- a named read-only root snapshot survives reboot, lists deterministically,
  restores through an atomic root swap, and deletes explicitly
- root snapshot creation fails explicitly when the resettable root contains a
  nested Btrfs subvolume; reset remains able to remove that root recursively
- snapshot restore removes later root changes while preserving later volume
  changes
- two environments share one explicitly mounted volume
- an environment without the mount cannot read that volume
- an environment cannot invoke the operator-only reset operation
- the public control socket cannot invoke reset
- resettable machine state and volume state survive control restart, generation
  switch, and rollback
- changed declarative configuration is visible after generation switch and
  returns to baseline after rollback

The proof uses harmless configuration and no real credentials.

## Hands-on shape

After building and enrolling the host, an SSH-compatible client uses the fixed
environment target. The current `/home/agent` path shown here is only a spike
convention pending the owner-account contract:

```bash
ssh atlas-shared-dev@<atlas-tailnet-host>
atlas environment inspect self --json
cd /home/agent/work
git clone <test-repository-url> repo-a
apt update
apt install <tool>
```

From the operator account, reset only the resettable environment instance:

```bash
atlas environment reset shared-dev --json
```

Or checkpoint and restore only its resettable root:

```bash
atlas environment snapshot create shared-dev before-upgrade --json
atlas environment snapshot restore shared-dev before-upgrade --json
atlas environment snapshot delete shared-dev before-upgrade --json
```

On the next entry, installed tools and home configuration are fresh while
`/home/agent/work/repo-a` remains.

## Deferred decisions

- runtime creation and deletion of definitions, instances, and volumes
- human owner account, conventional home layout, and environment-local elevation
- automatic creation and attachment of primary durable owner storage
- protected host recovery capacity and optional quotas for additional
  environments
- encrypted physical storage, unlock, recovery, and backup policy
- quotas for volumes, logs, recordings, and caches
- durable task supervision and reconnection semantics above ordinary Linux
  process tools
- copy-on-write volume forks, snapshots, backups, quotas, and ownership
- read-only and per-human volume authorization beyond the declared v0 mount
- private outbound networking with DNS and update behavior
- removal of broad Nix-store visibility from the environment
- materialized and brokered grant injection
- client-specific remote-target adapters

These decisions must preserve conventional Linux behavior, explicit volume
attachment, reset semantics, and peer-derived identity.
