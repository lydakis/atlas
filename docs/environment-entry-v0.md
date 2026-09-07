# Environment Entry v0

Status: persistent-service, reboot-persistent resettable root, durable owner
home composition, and durable-volume adapter implemented and KVM-proven

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
`GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`, `HOME`, `LOGNAME`, `PATH`, `SHELL`,
and `USER`, cannot be supplied by a layer or instance.

A layer is convenience, not a trust boundary. Two environments created from the
same layer do not share identity, mutable OS state, processes, or grants.

### Environment instance

An environment instance is the mutable realization of a definition. It has:

- an opaque Atlas identity independent of its human-readable name
- a kernel-enforced principal and cgroup boundary
- a resettable root filesystem and environment-local home paths
- a process and resource-accounting scope
- an effective non-secret configuration snapshot
- declared network behavior
- references to volumes, grants, surfaces, routes, and activity

The instance is reusable across entries and resettable over its lifecycle.
Installed packages, `/etc`, environment-local home paths, and root-filesystem
changes survive an SSH disconnect, environment restart, host reboot, and
supported update. `atlas environment reset <name>` terminates the instance and
deliberately destroys those changes. The Incus adapter deletes and recreates the
instance from the pinned system image before reset returns. Durable owner-home
data is mounted outside that replacement and is not restored by an instance
snapshot.

The host-owned Incus instance configuration records the complete instance-layout
identity required by the active generation only after devices and guest
provisioning succeed. The mutable environment root cannot rewrite that
authority. Missing readiness identity is treated as interrupted construction
and recreated automatically. A changed image, owner account, home composition,
elevation policy, network attachment, control surface, or durable-volume mount
requires explicit reset. Atlas instances use no mutable Incus profiles. A
matching identity is accepted only after Atlas also verifies the complete local
and expanded device configuration and rejects unexpected effective instance
configuration. Instances remain non-autostarting after verification; Atlas-owned
systemd units start declared environments only after inventory reconciliation.
Failed or drifted instances are stopped before reconciliation returns an error.
Configuration-only generation changes outside that layout continue to preserve
the root.

The pre-release Incus adapter is forward-only. Atlas does not adopt or rewrite
instances missing the current identity markers or device layout. Such drift
fails closed and requires explicit reset.

Host activation inventories Atlas-marked Incus instances. If an instance is no
longer declared, Atlas disables its autostart and stops it before host readiness
completes. It does not delete the instance, its root, or its named snapshots, so
the operator can recover or explicitly remove the quarantined state.

The guest-visible control contract is the only file published through a
dedicated generation-stable host directory. NixOS activation atomically
replaces that directory entry, so a running instance observes the active
generation without remounting a generation-specific file inode.

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
Installed packages, `/etc`, the declared resettable home paths, caches, and
other normal root filesystem contents belong to resettable machine state.
Conventional temporary locations may be cleared only under an explicit,
discoverable policy.

### Volume

A volume is durable operator-owned data with its own identity and lifecycle. An
environment definition attaches it at an explicit absolute path, read-write or
read-only. Repositories, worktrees, datasets, and artifacts that must survive
environment replacement belong on a volume.

An environment does not own an attached volume. Resetting or deleting its
instance must not delete volume contents. Multiple cooperating environments may
mount the same volume deliberately. An environment without that mount must not
be able to reach it through its filesystem.

Atlas automatically manages one owner-home volume and may compose it into an
environment at `/home/<owner>`. The current proof composes it into `shared-dev`
and `personal-dev`, while `restricted` receives an environment-local resettable
home and no durable owner data. The separate `projects` volume is mounted at `/home/owner/Projects` in the
two cooperating environments and omitted from `restricted`.

The mounted owner home is durable by default. Atlas overlays these
environment-local paths from the resettable root:

- `~/.config`
- `~/.cache`
- `~/.local/bin`
- `~/.local/state`

`~/.local/share`, repositories, documents, artifacts, and ordinary files under
the home remain durable. Two environments may therefore see the same owner
files while receiving different tool configuration, caches, local executables,
and local state. Root snapshot, restore, and reset include the overlaid paths
but exclude the durable home beneath them.

This boundary is explicit rather than heuristic. A dotfile such as `~/.bashrc`
or application state written outside the declared resettable paths remains
durable. Atlas must not claim it can identify arbitrary configuration by
filename. A later contract may make the list configurable, but v0 keeps one
small, inspectable default.

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

An entry runs as the configured human-owner account and UID, with a conventional
home at `/home/<owner>`. The account has passwordless `sudo` inside the Ubuntu
environment so agents can use normal instructions such as `sudo apt install`
without receiving Atlas-host root. In the current single-owner model, every
process admitted to that environment can obtain its environment-local root and
read or modify everything mounted there. Separate environments, omitted
volumes, and future Grants are the authority boundaries when that is too broad.

Several human or agent-driven processes may share the account. The account is
the human owner's execution context, not an agent identity. User namespaces map
environment root away from host root. This is a prototype isolation mechanism,
not a claim that every possible container escape has been excluded.

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
Several environments may mount one project volume and the durable owner home
while keeping installed packages, `/etc`, and the declared resettable home paths
separate. Atlas does not serialize Git operations or make concurrent writes
safe. Operators and agent tools still own that coordination.

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
Git configuration is redirected to `~/.config/git/config`, lives in the
resettable environment view, and is removed by reset. Atlas provisions the
parent directory so ordinary `git config --global` writes work on first entry.
If a config file must be durable, the operator may deliberately place it
outside the resettable paths and link or include it, accepting the shared-data
semantics.

SSH keys, signing keys, GitHub tokens, credential helpers containing secrets,
and other authentication material are grants, not environment configuration.
A future materialized-secret grant may add a value to one process, but it must
be reported as degraded and must not place a secret in a definition, layer, or
Nix derivation.

## Local control interface

Atlas exposes two versioned Unix-domain sockets. The public endpoint is
`/run/atlas/public/control.sock` and supports read-only discovery and
inspection. A separate mode-`0600` management socket supports lifecycle
mutation. Both authenticate the kernel-observed peer. The service derives an
environment from the peer UID or an anchored cgroup prefix; unknown identities
fail closed, and a descendant cgroup merely named after a different environment
cannot forge identity. Caller-authored labels do not establish authority.

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

- pins the Linux Containers Ubuntu Noble 24.04 Incus system image by exact
  metadata and rootfs hashes for both supported architectures, derives its
  Atlas image identity and alias from those hashes, and accepts that alias only
  when its immutable Incus fingerprint matches the pinned bytes
- imports that image into the local Incus 7.0 LTS daemon and creates one
  profile-free persistent unprivileged container per declared environment
- uses an isolated ID map for every container, disables the Incus guest API,
  and never exposes the administrative socket inside an environment
- enters as the human-owner UID through a fixed host login and a
  host-authorized `incus exec` launcher with environment-local passwordless
  `sudo`
- mounts the host Nix store and Atlas contract read-only, then adds declared Nix
  tool closures to the ordinary Ubuntu `PATH`
- composes the durable owner home and declared volumes through shifted disk
  devices while keeping resettable home paths on dependent Incus volumes
- gives each environment a separate network namespace, static private address,
  and the `atlas-private` NIC ACL
- proxies only the public Atlas control protocol into each container through a
  listener bound to that declared environment identity
- keeps the root-only Atlas lifecycle and Incus administrative sockets on the
  host
- creates, lists, restores, and deletes Incus instance snapshots through the
  root-only lifecycle surface, rejecting restore before mutation when the
  snapshot's complete effective configuration does not match the active
  declaration
- resets an environment by deleting and recreating its instance from the pinned
  image while verifying the durable owner home did not change
- forces all internal Incus commands to the local daemon rather than consulting
  ambient remote configuration

Entries reuse one persistent Incus instance. Several clients can enter it at
once and share its mutable OS state. Atlas does not provide a durable task
abstraction or reconnect arbitrary client-owned PTYs after their client exits.

Private IPv4 addresses are derived from the environment UUID, not its name or
position in the declaration, and reported as `network.ipv4Address`. The adapter
uses `10.211.0.0/16`, reserving `10.211.0.1` for the bridge and allocating from
`10.211.1.1` through `10.211.254.254` with both final octets in `1..254`.
Host networks must not overlap this fixed private subnet. The first eight
hexadecimal digits of SHA-256(UUID), modulo 64516, select the slot. A collision
within the declaration or a declaration exceeding 64516 environments fails Nix
validation; no existing address is reassigned to make room. On collision,
choose a different UUID for the new environment before creating it. Changing
an existing UUID means changing its identity, not just its address. Renaming a
definition preserves its address, but does not migrate the name-bound Incus
instance or its resettable state.

The persistent VM places the Incus Btrfs pool and Atlas durable volumes on the
dedicated data filesystem. The installed-host layout reserves host recovery
capacity and encrypts Atlas state in the KVM proof, but physical recovery,
optional quotas, and durable-data backup remain absent. The read-only host Nix
store remains visible and is reported as degraded tool isolation.

This adapter proves the lifecycle and identity seam. Incus is the only current
environment mechanism, while the Atlas protocol remains the stable product
boundary above it.

## Acceptance story

1. Atlas creates the configured owner's durable home and the owner declares a
   separate durable `projects` volume and three environments.
2. `shared-dev` and `personal-dev` receive the owner home and mount `projects`
   at `/home/owner/Projects`; `restricted` receives neither.
3. An existing SSH-compatible client enters `shared-dev`, clones a repository
   onto the volume, and commits with its managed Git identity.
4. `personal-dev` sees durable owner files and the repository, but retains a
   different `/etc`, resettable home configuration, installed tool set, and Git
   identity.
5. A human or agent-driven process installs a Debian package and changes `/etc`
   with environment-local administrative authority in
   `shared-dev`. Neither change appears in `personal-dev`.
6. A second client concurrently enters the same `shared-dev` instance and sees
   its state.
7. The host reboots. Its package, `/etc` change, resettable home configuration,
   durable owner files, and repository remain; live process state and `/run` do
   not.
8. The operator snapshots `shared-dev`, makes another root change, and restores
   the snapshot. The later root change disappears while later volume data
   remains.
9. Reset is refused while the named checkpoint exists. The operator explicitly
   deletes it, then resets `shared-dev` while a workload is active. Its package,
   process tree, `/etc` change, and resettable home paths disappear; durable
   owner files and the repository remain.
10. `restricted` cannot see the project volume and cannot reset another
   environment.
11. New resettable state and the durable repository survive control-service
    restart and NixOS generation switch and rollback.

## Proven in the KVM contract

The current x86 KVM integration test passed on August 31, 2026. It verifies:

- deterministic layer, package, Git, variable, volume, and owner-home
  composition plus fail-closed option evaluation
- fixed owner entry into persistent unprivileged Incus instances
- host-bound environment identity through the public UNIX proxy, with no
  caller-authored identity accepted
- no Incus administrative or guest API socket inside an environment
- Ubuntu package installation and `/etc` mutation isolated to one instance and
  persistent across restart
- durable owner and declared-volume sharing only among selected environments
- instance snapshots that roll back root and dependent resettable paths while
  preserving later durable writes
- reset refusal while named snapshots exist, preserving checkpoints until
  their explicit deletion
- delete-and-recreate reset that removes package, root, and resettable-home
  drift while preserving the Btrfs identities of the durable owner home and
  declared volumes
- a generation-stable guest contract directory whose atomically replaced file
  becomes visible without recreating the environment
- separate network namespaces with the private NIC ACL applied
- UUID-stable IPv4 addresses and a controlled connection matrix covering
  same-port loopback isolation, cross-environment denial, host-local denial,
  forwarded LAN/tailnet/metadata denial, DNS, and forwarded public-address egress
- the same matrix after adding a definition and after reboot into the original
  generation, without renumbering existing environments
- Incus daemon restart without losing the running environment or durable data

Live deployment revalidation, resource-limit enforcement, broader update/recovery,
and physical installation remain separate proof work.

## Hands-on shape

After building and enrolling the host, an SSH-compatible client uses the fixed
environment target:

```bash
ssh atlas-shared-dev@<atlas-tailnet-host>
atlas environment inspect self --json
cd /home/owner/Projects
git clone <test-repository-url> repo-a
sudo apt update
sudo apt install <tool>
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

On the next entry, installed tools and the declared resettable home paths are
fresh while `/home/owner/Projects/repo-a` and ordinary durable owner files
remain.

## Deferred decisions

- runtime creation and deletion of definitions, instances, and volumes
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
