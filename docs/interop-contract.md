# Atlas interoperability contract

Status: design contract, revised August 2026

This document defines how existing agent interfaces use Atlas without
surrendering their conversation, project, terminal, or product model. It
describes required behavior, not a chosen isolation backend or control-plane
implementation.

## Core rule

An existing agent tool should experience an Atlas environment as a normal
remote Linux target.

The baseline integration is an ordinary environment entry such as an SSH login,
remote-development target, or environment login shell. Once inside, Codex,
Herdr, T3 Code, Blue, an agent CLI, or a human operator manages its own
projects, repositories, worktrees, terminals, processes, and conversations.

No plugin does not mean no enforcement boundary. A process receives Atlas
environment capabilities only after entering through an authenticated identity
that the host maps to a kernel-enforced environment boundary. A process running
directly as the host administrator is outside that guarantee.

## Ownership

| Concern | Owner |
| --- | --- |
| conversations, tasks, prompts, models, agent selection | agent client or harness |
| projects, repositories, branches, worktrees, diffs | agent client, Git, or operator |
| terminals, panes, client reconnection, presentation | agent client or harness |
| host installation, health, update, rollback, recovery | Atlas |
| environment definition, identity, isolation, durable home, resource budget | Atlas |
| browser profiles, displays, observation, recording, takeover | Atlas |
| local credential grants and use attribution where observable | Atlas |
| private routes from paired devices to environment services | Atlas |
| downstream authorization policy | operator or consuming product |
| optional remote relay and rendezvous | deployer-selected service |

Atlas may supervise processes for containment and recovery without claiming
ownership of the client's logical session. It does not create a universal
namespace for projects, threads, panes, or coding tasks.

## Actors

- **Operator:** the human who owns or administers the host and grants authority.
- **Operator device:** a paired computer, tablet, or phone used for host
  operations, approvals, observation, and recovery.
- **Agent client or harness:** Codex, Herdr, T3 Code, Blue, an agent CLI, or
  another tool that connects to and runs inside an environment.
- **Environment process:** an untrusted process tree running with an
  Atlas-assigned kernel identity and boundary.
- **Atlas host services:** privileged processes that manage environments,
  grants, surfaces, routes, host health, and recovery.
- **Private-network provider:** initially Tailscale, which supplies reachability
  but does not replace Atlas authorization.
- **Optional remote service:** a replaceable rendezvous, relay, public-sharing,
  update, or off-host audit service.

## Resource model

Atlas exposes five primary resources.

### Host

A `host` is a paired Atlas machine. Its observable contract includes:

- stable host identity and human-safe name
- hardware and software architecture
- connectivity and enrollment state
- supported environment, grant, surface, and route capabilities
- storage, encryption, backup, update, rollback, and recovery conformance
- current health, resource pressure, and security-relevant degradation

### Environment

An `environment` is a named, reusable trust context realized as a persistent
Linux compartment. An existing agent client selects or enters it before work
begins. It owns:

- an enforceable OS principal and process boundary
- a private writable home and runtime state
- a resource budget and accounting scope
- a network context and outbound policy
- non-secret configuration
- references to its grants, surfaces, routes, and activity

An environment is not a repository, branch, task, terminal, or agent. Those
objects may exist inside it and remain owned by the selected client.

Secret values are not environment configuration. Source credentials remain in
an operator-owned or Atlas control-plane store by default. An explicit
materialized-secret grant is the degraded exception that copies a credential
into an environment. The environment references grants that define which
authority it may use and how that authority is delivered.

Environment labels are not security identities. The host derives authority
from the authenticated entry path, OS principal, cgroup or scope membership,
namespace membership, and any stronger selected isolation backend.

Each environment also has an opaque, non-reusable Atlas identity. Deleting an
environment requires an explicit lifecycle action for its bound profiles,
grants, surfaces, and routes. Recreating the same human-readable name inherits
nothing.

Some agent products also use `environment` for a saved launch configuration or
runner destination. A client environment may select an Atlas environment, but
the two identifiers are not interchangeable and neither a matching name nor a
client-supplied identifier establishes host authority.

### Grant

A `grant` is operator-approved authority bound to one environment by default.
It includes:

- requesting environment and, where provable, requesting process
- downstream audience and allowed operations
- issue, expiry, renewal, denial, and revocation state
- delivery mode: materialized runtime secret, derived or brokered authority, or
  browser-identity authorization
- evidence of use where the protocol makes that observable

A process can request authority but cannot approve its own request. A grant
cannot be replayed by another environment merely by copying an identifier.

### Surface

A `surface` is a browser or graphical desktop that can have an agent controller,
operator observers, and at most one interactive controller at a time. Its
contract includes:

- bound environment and trust level
- ephemeral or persistent profile policy
- automation interface and its authority
- current controller, observers, and takeover state
- recording, screenshot, clipboard, download, and retention policy

Browser control is account authority. A screenshot-and-action interface and a
raw browser-debug protocol are different capabilities and must be reported as
such. Atlas must not imply that cookies remain inaccessible when the selected
automation protocol can export them.

### Route

A `route` maps a service inside one environment to an authenticated private
endpoint. Its contract includes:

- owning environment and target process or network namespace
- target port and protocol
- private or explicitly public visibility
- authorized devices or tailnet identities
- lifetime, limits, health, and recent access evidence

Port discovery creates metadata only. It never creates a route by itself.

## Existing-tool entry

### Level 0: normal remote Linux

The first compatibility level requires no Atlas-specific conversation plugin.
The client connects to an environment through SSH or another conventional
remote target and receives:

- a normal shell, filesystem, home directory, and loopback network
- the toolchain installed for that environment
- isolation from the host control plane and other environments
- conventional credential helpers and a bounded surface-action endpoint where
  granted; raw browser debugging is not a Level 0 guarantee
- private service routing without opening public ports

The client continues to own process and PTY lifetime unless it explicitly asks
Atlas to supervise a declared service. Atlas does not promise to reconstruct an
arbitrary client-owned terminal after disconnection or reboot.

### Level 1: capability-aware

A client may use versioned local interfaces for structured environment status,
grant requests, surface creation or attachment, route requests, and activity.
These capabilities improve the experience but do not replace the Level 0 path.

### Level 2: policy-integrated

A product such as Blue may supply signed workload provenance or downstream
authorization policy. Atlas still enforces only its machine-local boundary and
must not infer that hosting a process authorizes Atlas to act as that product's
principal.

## Local and remote interfaces

### Conventional interfaces first

Atlas should prefer interfaces existing tools already understand:

- SSH and standard Linux users
- filesystem permissions and dedicated home directories
- Unix sockets and peer credentials
- standard credential helpers and SSH agents
- loopback ports and HTTP proxies
- bounded browser computer-use adapters
- WebDriver or debugging protocols only as separately granted, explicitly
  degraded capabilities equivalent to reusable browser authority

### Administrative CLI

The `atlas` CLI is a host administration and automation surface. It is not the
primary coding interface.

Illustrative commands are:

```bash
atlas status --json
atlas doctor --json
atlas pair
atlas environment list --json
atlas environment inspect <name> --json
atlas grant approve <request> --json
atlas surface observe <surface>
atlas surface take-over <surface>
atlas route open <environment> --port 3000 --private
atlas update
atlas rollback
```

Command names remain illustrative until an implementation proposal is
accepted. Automation-safe commands use versioned machine-readable responses,
structured error codes, and idempotency keys where retries are plausible.

### Local control interface

A versioned local interface may be available over a Unix-domain socket for
clients that need streaming events or structured capabilities. The service
authenticates callers using peer credentials and their observed environment
membership. Request fields such as `environment_id`, `agent_id`, or
`workspace_id` never establish authority.

### MCP adapter

An MCP server may expose safe subsets of grants, surfaces, routes, health, and
activity to compatible clients. MCP is an adapter, not the canonical control
plane. Disabling it cannot remove normal SSH access or the host's local
management path.

### Remote operator interface

The operator CLI or console reaches the host over the selected private network,
an SSH tunnel, a direct private path, or a replaceable relay. Requests remain
bound to a paired operator identity and are evaluated by the host. Network
reachability alone does not confer operator authority.

## Environment semantics

1. Each environment has a distinct kernel-enforced principal.
2. Separate environments cannot read, signal, trace, attach to, or consume each
   other's files, processes, browser profiles, grants, surfaces, or routes by
   default.
3. Child processes remain inside the parent's environment boundary.
4. Host-administrator and Atlas control-plane authority are unavailable inside
   ordinary environments.
5. Writable state is private to one environment unless a shared resource is
   explicitly declared and mediated.
6. Shared package or repository caches are immutable or brokered so one
   environment cannot poison another.
7. The isolation backend and its known gaps are discoverable through
   conformance rather than inferred from a marketing label.
8. Unless Atlas can prove a narrower process identity and confinement boundary,
   authority delivered to an environment is treated as usable by every process
   inside it.
9. An environment may contain multiple repositories, worktrees, agent
   processes, and client sessions because Atlas does not own those concepts.

An implementation may use Linux users, systemd scopes, namespaces, containers,
microVMs, or VMs. The contract is the observable boundary, not the backend.

An operator uses separate environments when agent instances require different
authority sets. This is guidance about selecting trust boundaries, not a claim
that Atlas can identify a client's logical agent instances.

## Grants and browser identities

An approval request includes the requesting environment, requested capability,
target service or identity, operations, duration, reason, and consequences.
Approval happens outside agent-controlled content.

The source credential is the reusable secret from which downstream authority is
obtained. It stays in a control-plane or operator-owned store by default. Where
a downstream system supports it, Atlas prefers narrow derivative credentials or
brokered operations over copyable bearer secrets.

Credential delivery has three explicit modes:

1. **Materialized runtime secret:** a source or derivative token, password,
   file, or environment variable is copied into the environment. Any process
   inside the environment may read and exfiltrate it. Capability discovery
   reports whether the materialized value is a source credential or a scoped
   derivative, and always reports this mode as degraded.
2. **Derived or brokered authority:** the source credential remains outside the
   environment while a helper performs narrow operations or issues a scoped,
   short-lived derivative credential. This is preferred when the downstream
   protocol supports it.
3. **Browser identity:** authentication state remains in a protected browser
   profile while the environment receives an explicit capability to operate
   its surface.

A browser profile is a credential container. Atlas binds it to one environment
and trust level, protects its files from environment processes unless the
declared automation capability requires broader access, and treats cookies,
history, downloads, clipboard, screenshots, and recordings as sensitive.

An environment authorized to operate a browser can act with the website
authority represented by that profile. Isolation prevents other environments
from acquiring that authority; it does not prevent the authorized environment
from misusing it.

The detailed authentication handoff, controller state, persistence policy, and
acceptance proof are defined by
[Authenticated Surface v0](authenticated-surface-v0.md).

## Connectivity and SSH

The first adapter is Tailscale. An Atlas image should support interactive or
short-lived-key enrollment, stable tailnet naming, and SSH over the tailnet.

Tailscale supplies reachability and may supply SSH authentication according to
tailnet policy. Atlas still controls local OS users, environment membership,
host administration, grants, surfaces, routes, and recovery. Tailnet membership
must not grant ambient access to every environment or operator-only method.

Administrative SSH and private routes are unavailable from public interfaces by
default. A separate local or console recovery path remains necessary because a
tailnet outage or policy mistake must not strand the host.

The core contract does not require an Atlas-operated cloud. Other private mesh,
direct network, or self-hosted adapters may be added when a second real adapter
justifies a generic connectivity seam.

## Route semantics

Atlas may observe that an environment process is listening on a port. Creating
a route requires an explicit operator or client action or a previously approved
environment policy.

Routes are private and authenticated by default, bind to the owning environment
and target namespace, reject arbitrary upstream destinations, and report
visibility, owner, expiry, limits, and health. Public sharing is a separate
expiring grant.

## Outbound network boundary

The default developer environment may use the public internet. Atlas isolates
what the environment can read and which authority it can obtain, but it cannot
prevent that environment from transmitting data it is legitimately allowed to
read.

Restricted or allowlisted egress may become a capability for higher-risk
environments. Until implemented and verified, Atlas must not imply data-loss
prevention, destination-level credential confinement, or protection against
exfiltration by an authorized internet-enabled environment.

## Durability contract

Durability refers to named state and declared reconstruction behavior, not
process immortality.

| Event | Guaranteed durable state | Not guaranteed |
| --- | --- | --- |
| client disconnect | environment files, declared services, persistent profile data, grant and route records according to policy, events | arbitrary client-owned PTY or connection-local streams; continued authority after expiry or revocation |
| environment process crash | files, declarations, persistent profile data, events | process memory; restart without declared policy |
| Atlas control restart | on-disk resources and already supervised declared services | uninterrupted operator attachment transport |
| host reboot | environment files, declared services, route and grant records with effective policy state, encrypted persistent profile data | process memory, PTY contents, ephemeral profiles; profile availability before its declared unlock condition is satisfied |
| OS update | state promised across reboot, subject to reported conformance | arbitrary unmanaged host changes |
| disk failure or machine loss | only configured and verified backups or replicas | unreplicated local state |

`atlas doctor` reports which rows the current host can satisfy.

## Capability discovery

The managed image and a future supported Linux install may expose the same
resource model with different guarantees. `atlas doctor --json` reports:

- contract and schema versions
- environment identity and isolation backend
- browser automation, observation, recording, and takeover capabilities
- whether raw browser credentials can be exported through the selected protocol
- destination-fact provenance, password-retention policy, and paired-device
  revocation and recovery capabilities
- credential delivery and brokering modes
- private connectivity and recovery paths
- route authentication and exposure modes
- storage, update, rollback, and backup guarantees
- known host conflicts and degraded guarantees

Clients degrade explicitly. They do not infer guarantees from the distribution,
installation method, or the presence of an `atlas` command.

## Non-goals

This contract does not define:

- conversations, prompts, tasks, or model selection
- repository, branch, worktree, merge, or diff semantics
- client terminal, pane, or logical session identity
- a remote code-editor protocol
- agent selection, assignment, or orchestration
- transparent live-process migration
- data-loss prevention for data an environment is allowed to read
- downstream product authorization
- a requirement to trust an Atlas-hosted remote service

## Architecture decisions intentionally open

The contract does not yet choose:

- final base Linux distribution or image-construction system
- persistent disk layout and supported unlock mechanisms
- environment isolation backend
- control-plane implementation language
- browser automation and streaming technology
- credential providers
- route proxy implementation
- hosted relay, rendezvous, or public-sharing provider

Those choices should be evaluated against this contract and the threat model,
not made prerequisites for discovering the product.
