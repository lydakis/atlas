# Atlas interoperability contract

Status: design contract, August 2026

This document defines how arbitrary agent interfaces use Atlas without surrendering their conversation, session, or product model. It describes required behavior, not a chosen implementation architecture.

## Core rule

Atlas integrates at the process running inside the machine.

An agent client only needs to start a process through an Atlas workspace entrypoint. Atlas-aware clients may use richer APIs, but baseline usefulness cannot depend on a conversation plugin for T3 Code, Herdr, the Codex app, Blue, or any other particular client.

No plugin does not mean no integration boundary. A client must invoke an Atlas-owned workspace shell, `atlas workload run`, or an equivalent stable entrypoint so the process receives the correct principal, resource envelope, and lifecycle supervision.

## Ownership

| Concern | Owner |
| --- | --- |
| conversations, tasks, prompts, model selection | agent client or harness |
| client terminals, panes, and presentation | agent client or harness |
| workspace identity and durable files | Atlas |
| workload lifetime, supervision, and resource accounting | Atlas |
| reattachable PTY, attachments, and control lease | Atlas |
| previews, browsers, displays, and attachment | Atlas |
| local credential delivery and use attribution | Atlas |
| downstream authorization policy | operator or consuming product |
| optional remote relay and rendezvous | deployer-selected service |

Atlas names resources beneath client concepts. It does not try to unify every client's thread or session namespace.

## Actors

- **Operator:** the human who owns or administers the host and grants authority.
- **Operator client:** a CLI or future web console used to pair, inspect, approve, attach, and recover.
- **Agent client or harness:** T3 Code, Herdr, Codex, Blue, an agent CLI, or another process launcher.
- **Workspace workload:** an untrusted process tree running with an Atlas-assigned identity and resource boundary.
- **Atlas host services:** privileged components that supervise resources and mediate access.
- **Optional remote service:** a replaceable rendezvous, relay, public-share, update, or off-host audit service.

## Required local surfaces

Atlas has two directions of control:

- the **workload plane** lets a process inside a workspace use machine capabilities under its kernel-derived identity
- the **operator plane** lets a paired human inspect, approve, attach, stop, and recover from another device

Both operate on the same resources and policy. They use different authentication and must not be collapsed into one ambient bearer credential.

### Shell-compatible baseline

A process in an Atlas workspace receives conventional operating-system behavior:

- a normal filesystem and working directory
- a stable workspace identifier in metadata, without authority being based on that value
- process and service supervision that is independent of the launching connection
- conventional loopback port binding and service discovery
- standard credential-helper integration where an ecosystem supports it
- `atlas` on `PATH`

An unmodified shell-based agent launched through the stable entrypoint must be able to benefit from workspace durability, private previews, and basic inspection. A process launched directly into a client-owned SSH PTY without crossing the entrypoint receives no Atlas guarantee of identity, supervision, or reattachment.

### CLI

Every automation-safe command must support a versioned JSON response. Human-readable output is a presentation of the same underlying model. The command set visible to a caller is authorized by its proven role.

```bash
# workload plane
atlas inspect --json
atlas preview request --port 3000 --json
atlas browser create --profile ephemeral --json
atlas credential request github --scope repo:read --json
atlas activity list --json

# agent-client launcher plane
atlas workspace shell project --json
atlas workload run --workspace project --pty -- command arg

# paired operator plane
atlas host inspect --json
atlas workspace list --json
atlas preview approve --request <id> --private --json
atlas browser attach --surface <id> --json
atlas grant approve --request <id> --json
atlas device revoke <id> --json
```

The relevant caller roles are workload, agent-client launcher, local host administrator, and paired remote operator. They may use one binary and resource schema, but each authenticates through a different context and receives only its authorized methods. In particular, a workload can request a grant but cannot approve one, and a launcher can create a workload without acquiring the workload's future credentials.

The command names are illustrative until an implementation proposal is accepted. The behavioral resources are part of the contract.

### Local API

A versioned local API should be available over a Unix-domain socket for clients that need streaming events, browser attachment, approvals, or efficient lifecycle control.

The service must authenticate the calling process using kernel-derived identity such as peer credentials, its assigned workspace principal, and its workload boundary. A request field that says `workspace_id` or `agent_id` is never sufficient authority.

### MCP adapter

An MCP server may expose safe subsets of the same resource model to compatible agents and clients. MCP is an adapter, not the canonical control plane. Disabling it must not remove the CLI or local API contract.

### Remote operator API

The operator CLI and console use an authenticated, versioned host API through a private network path, SSH tunnel, or selected relay. Requests are bound to a paired operator device and evaluated by the host. A relay must not be able to manufacture operator or host authority.

The remote API may share schemas and resources with the local API, but it exposes an operator-specific authorization surface. A workload cannot reach operator-only methods merely by connecting to the same transport.

## Resource model

Atlas exposes two related groups of resources.

Operator-plane resources:

- `host`: a paired Atlas machine, its capabilities, health, policy, and recovery state
- `device`: a paired operator device or client identity with lifecycle and revocation state
- `operation`: an observable, cancellable where safe, long-running control-plane action

Execution-plane resources:

- `workspace`: a durable, forkable branch of files, metadata, policy, writer ownership, and reconstruction information
- `workload`: a supervised process tree bound to one workspace branch, with identity, limits, lifecycle, and exit state
- `session`: a host-owned reattachable PTY or other I/O session bound to a workload, with observers and an exclusive control lease
- `surface`: a private preview, browser, display, screenshot, recording, or attachment endpoint
- `grant`: an operator-approved, scoped, expiring capability bound to a workload by default
- `event`: an attributable record of a lifecycle, access, policy, or sensitive-use action

Identifiers are opaque and stable within the lifetime documented for each resource. User-supplied labels are not security identities.

The complete execution context is the relationship among a workspace branch, its workload, resource and network boundaries, sessions and surfaces, grants, and event stream. It is an aggregate, not a replacement for the individual resources.

## Workspace and workload semantics

The initial contract chooses explicit state ownership over shared mutation:

1. A workspace branch has one active writer lease.
2. A writable workload must hold that lease. Independent concurrent writers use forked workspace branches.
3. A workload is bound to exactly one workspace branch for its lifetime.
4. Processes inside one workload may interact according to its isolation profile. Separate workloads cannot signal, trace, attach to, or consume each other's resources by default.
5. A grant is workload-bound by default and disappears or becomes unusable when that workload ends. Workspace policy may preauthorize a future request, but it does not place a credential in every future workload.
6. Child processes remain in the parent's workload boundary. A container or VM that cannot preserve that boundary must be launched as a registered nested or separate workload.
7. Terminal or browser takeover grants one caller an exclusive control lease while allowing explicitly authorized observers.
8. Moving a writable branch to another host checkpoints durable state, transfers the writer lease, and reconstructs declared resources. It does not migrate process memory.

Clients can attach concurrently for observation. Mutating control, terminal input, browser takeover, and writer ownership require explicit lease semantics rather than last-writer-wins behavior.

## Terminal and process continuity

Atlas distinguishes process survival from interactive continuity.

- Declared services and noninteractive jobs are supervised independently of the launching connection.
- Interactive continuity is guaranteed only when Atlas owns the PTY as a `session` resource and the client attaches through its stream.
- A disconnected attachment does not terminate the session or workload.
- Only the holder of the session's control lease can write input. Other authorized attachments are observers.
- A host reboot does not preserve process memory or PTY state. Atlas reconstructs only resources declared as restartable.
- A process launched in a client-owned PTY may survive according to that client's behavior, but Atlas does not promise reattachment to arbitrary stdin and stdout streams.

## Identity and attribution

The host maps every workload to an enforceable kernel boundary, initially expected to include an OS principal plus a systemd scope or cgroup. Stronger isolation may add user namespaces, containers, microVMs, or separate VMs.

Atlas authorizes local requests from observed process identity and boundary membership. Capability tokens are used only when authority must cross a boundary that kernel peer identity cannot cover. Tokens must be scoped, short-lived, audience-bound, and revocable.

Activity records distinguish at least:

- operator action
- agent-client action
- workspace workload action
- Atlas control-plane action
- optional remote-service action

Atlas records what it can prove. It must not claim to know which model, prompt, or logical subagent caused an operation unless the client supplies signed or otherwise trustworthy provenance.

## Response and compatibility rules

Machine-readable responses use an envelope with:

- schema version
- request or operation identifier
- resource identity and state
- structured result or error code
- human-safe diagnostic text
- links or capability handles where applicable

Compatibility rules:

1. Existing fields retain meaning within a major schema version.
2. New optional fields may be added without a major version change.
3. Automation branches on error codes, not prose.
4. Long operations return an operation resource and observable state transitions.
5. Repeated mutating requests support idempotency keys where retries are plausible.
6. Sensitive values are never returned in logs, diagnostics, or activity records.

## Capability discovery and conformance

The managed image and supported Linux install expose the same resource model. They can provide different guarantees.

`atlas doctor --json` reports:

- contract and schema versions
- available resource capabilities
- isolation and identity backend
- preview, browser, and display support
- credential broker support
- connectivity and recovery paths
- update and rollback guarantees
- known host conflicts or degraded guarantees

A client asks for capabilities and degrades explicitly. It does not infer guarantees from the distribution name or installation method.

## Approvals

Approval is a control-plane action, not a terminal prompt injected into an agent session.

An approval request includes the requesting workspace and workload, requested capability, target service, scope, duration, reason, and consequences. Approval may occur through the CLI or operator console. The resulting grant is bound to the requesting principal and cannot be replayed by another workspace.

## Service discovery and publication

Atlas may automatically discover that a workload is listening on a port. Discovery creates local metadata only. It does not create a remotely reachable route.

A route requires either an explicit operator or client action or a previously approved workspace policy. The route is private and authenticated by default, bound to the workspace and target workload, and visible in activity. Public sharing is a separate expiring grant.

## Connectivity

The local contract does not require an Atlas-operated cloud. Remote clients may reach the host through a private mesh, direct network path, SSH tunnel, or a selected relay.

Pairing establishes device and operator trust. Network reachability alone does not confer Atlas authority. Public preview sharing is a separate, explicit capability and is never the default form of service discovery.

### Outbound network boundary

Atlas v0 permits ordinary internet egress for the default developer workload profile. Atlas isolates what a workload can read and which credentials it can obtain, but it does not prevent that workload from transmitting data it is legitimately authorized to read.

Restricted or allowlisted egress can become an isolation capability for higher-risk profiles. Until then, Atlas must not imply data-loss prevention, destination-level credential confinement, or protection against exfiltration by an authorized internet-enabled workload.

## Durability contract

Durability refers to named state with explicit reconstruction behavior, not magical process immortality.

| Event | Guaranteed durable state | Not guaranteed |
| --- | --- | --- |
| client disconnect or network change | workspace files, events, supervised workload, declared services, Atlas-owned session | client-owned PTY or connection-local streams |
| workload process crash | workspace files, events, declarations, persistent profile data | process memory; restart occurs only by declared policy |
| Atlas API daemon restart | on-disk resources, already supervised workloads, and Atlas-owned PTYs; control state is reconciled | uninterrupted attachment transport during restart |
| host reboot | workspace files, events, declared services and routes, persistent profiles according to policy | process memory, PTY contents, ephemeral profiles |
| OS update | the same declared state promised across a reboot, subject to reported conformance | arbitrary unmanaged host state |
| move to another host | checkpointed files, metadata, declarations, selected profiles and artifacts | live processes, open sockets, transient memory |
| disk failure or machine loss | only state present in a configured and verified backup or replica | unreplicated local state |

`atlas doctor` reports which rows the current host can satisfy. Backup, checkpoint, fork, and host movement are distinct operations and must not all be labeled sync.

## Client integration levels

- **Level 0, shell-compatible:** the client invokes the stable Atlas workspace entrypoint to start an unmodified agent and gains durable execution, conventional filesystem behavior, CLI access, and private service discovery. Reattachable interactive continuity requires an Atlas-owned session.
- **Level 1, capability-aware:** the client consumes JSON, MCP, or the local API for structured previews, browser attachment, lifecycle, approvals, and activity.
- **Level 2, policy-integrated:** a product such as Blue supplies its own signed workload provenance and authorization policy while Atlas continues to enforce only machine-local grants.

All levels use the same host resources. Higher levels add provenance and user experience, not a separate runtime.

## Non-goals

This contract does not define:

- a conversation, prompt, task, or model API
- a universal namespace for third-party client sessions
- a remote code editor protocol
- a container or VM format
- agent selection, task assignment, or multi-agent orchestration
- transparent live process migration
- concurrent shared mutation of one workspace branch
- data-loss prevention for data an internet-enabled workload is allowed to read
- downstream product authorization
- a requirement to trust an Atlas-hosted service

## Architecture decisions intentionally left open

The contract does not yet choose:

- base Linux distribution or image construction system
- mutable, image-based, A/B, OSTree, Nix-style, or other update design
- exact workspace isolation backend
- private networking implementation
- control-plane implementation language
- browser automation protocol and streaming technology
- hosted relay, rendezvous, or public-share provider

Those choices should be evaluated against this contract and the threat model, not made prerequisites for discovering the product.
