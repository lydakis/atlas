# Atlas threat model

Status: initial design threat model, August 2026

## Overview

Atlas turns a physical or virtual Linux machine into a remotely operated host for autonomous or semi-autonomous agent workloads. The host supervises durable workspaces and processes, exposes private previews and visual surfaces, brokers delegated credentials, and lets an operator inspect or take control.

This repository contains product and interface design documents plus a bounded NixOS host architecture spike. The spike demonstrates a few host-policy controls, but it is not an Atlas implementation. The intended product boundary is defined in `docs/product-thesis.md`, and the caller, resource, and lifecycle contract is defined in `docs/interop-contract.md`. Except where `docs/nixos-spike.md` records runtime evidence, every mitigation below remains a security requirement or candidate control, not a claim about a complete product.

### Security objective

Assume that agent workloads, generated code, repositories, dependencies, browser content, tool output, and remote websites can all be malicious. Atlas should contain their authority to an explicit workspace and workload, prevent silent access to host or operator secrets, keep exposed surfaces private unless deliberately shared, and preserve evidence sufficient for investigation and revocation.

### Highest-value assets

- operator identity, pairing keys, device keys, and recovery authority
- source credentials from which delegated access is derived
- short-lived tokens, SSH material, browser cookies, and authenticated profiles
- source code, uncommitted work, artifacts, and workspace history
- Atlas control-plane privileges and host root authority
- signing keys, build provenance, update metadata, and recovery images
- host identity, network membership, DNS names, and preview routes
- audit records and evidence of sensitive actions
- host compute, storage, network, and service availability
- downstream product identities, including Blue and Fabric principals

### Scope

The initial scope includes the Atlas host, its managed or integrated Linux installation, local APIs and CLI, workspace branches and writer leases, workload and session boundaries, preview routing, browser and display services, credential brokering, inbound and outbound networking, pairing, remote operator access, updates, recovery, and optional Atlas-compatible remote services.

The operator device, third-party agent clients, downstream services, private-network provider, and distribution supply chain are external systems whose trust relationships must be explicit.

## Threat Model, Trust Boundaries, and Assumptions

### Actors and attacker capabilities

- **Legitimate operator:** pairs devices, creates workspaces, grants access, approves sensitive actions, and performs recovery. The operator can still make dangerous mistakes.
- **Agent workload:** runs attacker-influenced code and commands. It may attempt privilege escalation, secret extraction, persistence, evasion, or interference with other workloads.
- **Agent client or harness:** launches and observes work but may be buggy, compromised, or dishonest about logical agent identity.
- **Malicious repository or dependency:** supplies build scripts, hooks, binaries, tests, or package lifecycle actions that execute within a workload.
- **Remote content attacker:** controls a website, prompt injection, tool response, API result, issue, document, or preview request seen by an agent.
- **Network attacker:** can scan or intercept reachable services and may control a local or public network, but does not initially possess trusted device keys.
- **Compromised workspace peer:** already controls one workspace and tries to cross into another workspace or the host.
- **Physical attacker:** steals or accesses a powered-off or unattended Atlas machine.
- **Supply-chain attacker:** compromises an Atlas dependency, build system, update channel, mirror, package repository, or optional remote service.
- **Resource-exhaustion attacker:** consumes CPU, memory, disk, file descriptors, ports, browser processes, or network capacity to deny service or evade logging.

### Trust boundaries

```text
Operator device
      │ pairing, approvals, attach, recovery
      ▼
Remote access boundary ───── optional rendezvous or relay
      │
      ▼
Atlas host control plane ─── update and supply-chain boundary
      │         │
      │         └──────── credential broker ─── downstream services
      │
      ├──────── workspace A / workload identity ─── internet and web content
      │                  │
      │                  ├── preview and browser/display surfaces
      │                  └── durable workspace storage
      │
      └──────── workspace B / workload identity
```

The important boundaries are:

1. **Operator device to host:** remote reachability must not equal operator authority.
2. **Agent client to host:** client-supplied labels are input, not authentication.
3. **Host control plane to workload:** workloads are expected to be hostile and must not write control-plane binaries, policy, sockets, logs, or update state.
4. **Workspace to workspace:** each workspace has separate identity, resources, files, profiles, grants, and event attribution.
5. **Workload to credential broker:** a workload receives only an approved derivative capability, never the operator's source credential.
6. **Workload to visual surface:** browser profiles, automation endpoints, displays, clipboard state, recordings, and takeover channels carry sensitive data.
7. **Workload to internet:** an internet-enabled workload can transmit any data and bearer capability it is allowed to read.
8. **Preview to network:** local services become reachable across a new routing and authentication boundary.
9. **Host to optional remote service:** rendezvous, relay, sharing, and audit services must have narrowly defined access and failure behavior.
10. **Installed system to update supply chain:** privileged updates can replace every local control.
11. **Persistent storage to physical access:** an unattended machine may contain source, tokens, browser state, logs, and pairing material.

### Assumptions

- The v0 operator is a single administrative trust domain. Safe multi-tenant hosting is not assumed.
- An operator device is trusted after cryptographic pairing until explicitly revoked.
- Kernel, firmware, hypervisor where present, and hardware root-of-trust mechanisms are outside Atlas's ability to make trustworthy after compromise.
- Agent workloads do not require unrestricted host root. Work that genuinely requires elevated authority crosses an explicit approval boundary.
- External services enforce the scopes and expiry of credentials they issue.
- Network privacy tools reduce exposure but do not replace application authentication and authorization.
- Recovery SSH is a privileged break-glass path and must be secured, observable, and revocable.
- Atlas may broker a downstream identity but is not automatically that downstream principal.
- The default v0 developer profile permits internet egress. Network isolation is not assumed to provide data-loss prevention.

### Security invariants

1. A process cannot gain authority by self-asserting a workspace, client, agent, or model identifier.
2. A process receives Atlas workspace capabilities only after crossing an authenticated launch boundary.
3. One workspace cannot read, signal, trace, attach to, route through, or consume grants belonging to another workspace unless policy explicitly allows it.
4. A writable workspace branch has one active writer lease. Independent concurrent writers use separate branches.
5. Agent workloads cannot modify the Atlas control plane, security policy, audit sink, update trust roots, or host credential store.
6. Source credentials are not present in workload environment variables, home directories, command lines, logs, or browser profiles.
7. A delegated grant is scoped to a principal, audience, operation set, and expiry, and can be revoked. It is workload-bound by default.
8. Browser profiles, cookies, debugging endpoints, recordings, clipboards, and downloads follow the same workspace boundary as the workload.
9. Preview routes are private and authenticated by default. Discovery alone does not publish a route. Public sharing is separate, explicit, narrow, expiring, and visible.
10. Pairing proves possession of operator and host key material, resists replay, and produces a revocable device relationship.
11. Security-relevant activity is recorded outside workload control and can be exported off-host or made tamper-evident.
12. Updates are authenticated, rollback-aware, and unable to silently reduce declared security guarantees.
13. Resource exhaustion in one workload does not prevent the operator from inspecting, stopping, or recovering the host.
14. Losing an optional hosted service does not remove local recovery or strand declared durable state.

### Explicit non-guarantees in the first design

- Atlas does not make arbitrary downloaded code safe.
- Atlas does not solve malicious or exploitable host kernels, firmware, or hypervisors.
- Atlas cannot prove prompt-level or logical subagent attribution without trustworthy client provenance.
- Atlas does not promise hostile public multi-tenancy in v0.
- Atlas does not prevent an explicitly authorized agent from misusing authority within the granted scope.
- Atlas v0 does not prevent an internet-enabled workload from transmitting source, artifacts, tokens, or other data it is legitimately allowed to read.
- Atlas does not make public previews safe merely by placing authentication in front of an exploitable application.
- Atlas does not guarantee confidentiality after an operator grants live browser or display takeover to a compromised device.

## Attack Surface, Mitigations, and Attacker Stories

### 1. Local control API and privileged helpers

**Attacker story:** A malicious repository sends requests to the Atlas Unix socket, spoofs another workspace identifier, exploits a parser or helper, and obtains host-level operations.

**Required mitigations:**

- authenticate Unix-socket callers from peer credentials and kernel-enforced workload membership
- minimize privileged API surface and split high-risk helpers by capability
- use typed, versioned messages with strict size, path, and argument validation
- never construct privileged shell commands from request strings
- bind every authorization decision to the observed principal and current policy
- rate-limit requests and make sensitive mutations idempotent and auditable
- fuzz parsers and add cross-workspace authorization regressions

### 2. Workspace isolation and host escape

**Attacker story:** Generated code exploits permissive mounts, Linux capabilities, device access, namespace configuration, Docker sockets, ptrace, or a shared cache to escape its workspace or steal another workspace's data.

**Required mitigations:**

- run workloads as distinct non-root OS principals with cgroup or systemd-scope ownership
- deny host Docker and control-plane sockets from ordinary workloads
- drop Linux capabilities, constrain devices, mounts, ptrace, IPC, and kernel interfaces
- use stronger container, user-namespace, microVM, or VM isolation where risk requires it
- partition writable state, browser profiles, caches, temporary directories, and runtime sockets
- allow cross-workspace cache reuse only through immutable content-addressed data or a mediated publication path; never use an untrusted shared writable cache
- make isolation guarantees discoverable through conformance, not inferred from marketing names

### 3. Credential broker and secret delivery

**Attacker story:** Prompt injection convinces an agent to request a broad token, reads it from another process, exfiltrates it to a website, or reuses it after the operator believes it was revoked.

**Required mitigations:**

- keep source credentials in a control-plane store inaccessible to workloads
- prefer on-demand protocol helpers or proxied operations over bearer-token materialization
- issue the narrowest available audience, repository, operation, and duration scope
- bind grants to the requesting workspace or workload and reject cross-principal replay
- show approvals outside agent-controlled output with exact scope and expiry
- log requests, issuance, use where observable, denial, expiry, and revocation without logging secrets
- support immediate revocation and quarantine of a compromised workspace
- treat services that cannot issue meaningfully scoped credentials as a documented degraded mode

### 4. Outbound network and data exfiltration

**Attacker story:** A malicious dependency or prompt-injected agent sends readable source code, artifacts, browser data, or a freshly issued bearer token to an attacker-controlled internet service.

**Required mitigations and declared limits:**

- state plainly that the default v0 developer profile permits ordinary internet egress and does not provide data-loss prevention
- prevent workload routes to the host control plane, other workspaces, cloud metadata endpoints, and private infrastructure unless explicitly delegated
- prefer audience-bound proxied operations over copyable bearer credentials where downstream services support them
- make egress capability and any restrictions visible through workload policy and `atlas doctor`
- support deny-by-default, destination-allowlisted, or proxied egress profiles for higher-risk work in later milestones
- record useful connection metadata when policy and privacy requirements permit, without implying that logging blocks exfiltration
- treat disclosure of data inside a workload's documented readable and network authority as misuse of granted authority, not proof of an isolation escape

### 5. Browser, display, and takeover

**Attacker story:** A hostile page steals an authenticated profile, reaches a browser-debug endpoint, reads clipboard or downloads, escapes through a browser vulnerability, or tricks an operator into taking over a deceptive session.

**Required mitigations:**

- isolate browser processes and profiles per workspace and trust level
- keep automation and debugging endpoints on authenticated local boundaries, never open wildcard listeners
- separate ephemeral automation profiles from high-trust human-assisted profiles
- make takeover state, controlling party, recording state, and return of control unambiguous
- require a fresh operator action before injecting sensitive input into an agent-visible session
- sanitize filenames and isolate downloads from executable control-plane paths
- patch browsers rapidly and consider stronger sandbox or VM boundaries for high-trust profiles
- treat screenshots, video, clipboard, and browser history as sensitive workspace artifacts

### 6. Preview discovery and routing

**Attacker story:** A workload publishes an unintended administrative port, uses the router for SSRF, steals another preview hostname, or causes an unauthenticated development server to become public.

**Required mitigations:**

- default every discovered service to private and unpublished
- require an explicit policy or command to create a route
- bind routes to workspace identity and verify the target process or namespace
- authenticate before proxying, use unguessable handles only as a secondary defense, and expire shares
- prevent arbitrary upstream targets, host-network pivots, metadata access, and cross-workspace routing
- display route visibility, owner, target, expiry, and recent access in activity
- apply request, bandwidth, and connection limits

### 7. Pairing, remote control, and recovery

**Attacker story:** An attacker observes a pairing code, replays enrollment, takes over an abandoned device, or uses recovery SSH to bypass Atlas authorization.

**Required mitigations:**

- use short-lived, single-use pairing ceremonies bound to host and device public keys
- require local or already trusted confirmation for high-impact enrollment where feasible
- authenticate and encrypt every control channel independently of private-network membership
- enumerate, expire, and revoke paired devices and active sessions
- make recovery SSH opt-in or tightly configured, key-only, separately logged, and revocable
- provide a physical or console recovery path that rotates host and device trust after compromise

### 8. Optional hosted services

**Attacker story:** A compromised rendezvous or relay redirects an operator, impersonates a host, reads relayed content, extends a public share, or blocks recovery.

**Required mitigations:**

- preserve end-to-end host and operator authentication through relays
- give rendezvous services metadata and routing authority only, not host-control credentials
- encrypt sensitive relayed payloads end to end where practical
- make public-share expiry and revocation host-enforced
- define offline and self-hosted paths and keep local recovery independent
- minimize retained metadata and document exactly what a hosted service can observe

### 9. Update and software supply chain

**Attacker story:** A malicious package, mirror, CI job, signing-key compromise, or downgrade replaces privileged Atlas components on every host.

**Required mitigations:**

- authenticate release metadata and artifacts with offline-protected trust roots
- produce reproducible or attestable builds with an auditable dependency inventory
- separate OS, Atlas, and workspace package trust domains
- prevent workloads from modifying update configuration or trusted keys
- use staged rollout, health checks, rollback, anti-downgrade policy, and emergency revocation
- surface update provenance and current security state through `atlas doctor`
- retain a documented recovery path that does not depend on the compromised channel

### 10. Audit integrity and attribution

**Attacker story:** A compromised workload deletes logs, floods the event stream, forges an agent identifier, or stores secrets in arguments so that Atlas itself leaks them later.

**Required mitigations:**

- write security events through a control-plane-owned path inaccessible to workloads
- use kernel-derived workspace and workload identity in records
- distinguish proven host identity from unverified client annotations
- redact environment values, tokens, headers, command payloads, and sensitive browser data by default
- rate-limit low-value events without dropping security state transitions
- chain, sign, or export important records to an operator-controlled off-host sink
- document retention and provide a deletion policy for sensitive recordings and artifacts

### 11. Resource exhaustion and availability

**Attacker story:** A fork bomb, browser swarm, disk-filling build, network flood, or log storm prevents inspection and leaves the host unrecoverable.

**Required mitigations:**

- apply per-workspace CPU, memory, process, file-descriptor, disk, and network budgets
- reserve resources for control-plane and recovery services
- enforce storage quotas and bounded logs, recordings, snapshots, and browser caches
- provide operator-visible pressure signals and deterministic stop, quarantine, and cleanup actions
- test recovery during exhausted memory and disk conditions
- keep destructive cleanup explicit and separate from durable-state deletion

### 12. Persistent storage and physical theft

**Attacker story:** A thief removes a drive or boots alternate media and extracts repositories, browser cookies, pairing keys, or cached credentials.

**Required mitigations:**

- support full-disk encryption with a documented unattended-boot tradeoff
- use hardware-backed key sealing where compatible with recovery requirements
- encrypt especially sensitive credential and browser stores separately where useful
- avoid retaining source credentials and minimize token lifetime at rest
- make remote device revocation and downstream credential revocation possible after theft
- define backup encryption, restore authorization, and secure factory-reset semantics

### 13. Integration collisions and confused deputy behavior

**Attacker story:** Two clients believe they own the same workspace or terminal, a client passes an Atlas capability to the wrong task, or Atlas applies Blue policy on behalf of a process it merely hosts.

**Required mitigations:**

- keep Atlas resource identities separate from client conversation and session identifiers
- allow one active writer lease per workspace branch and require forks for independent concurrent mutation
- require an exclusive control lease for terminal input and browser takeover while keeping observer attachment explicit
- scope capabilities to audience and principal rather than reusable bearer handles
- bind grants to workloads by default; workspace policy may preauthorize a request but must not make a reusable credential ambient
- make lifecycle ownership and takeover visible to all attached operators or clients
- keep downstream authorization in the consuming product and enforce only explicit machine-local grants
- never let Atlas act as a Blue or Fabric principal solely because it hosts a Blue workload

## Severity Calibration (Critical, High, Medium, Low)

Severity reflects impact plus plausible exploitability on a dedicated agent host. Internet-reachable, cross-workspace, no-interaction, persistent, or supply-chain-wide paths raise severity. Explicit operator action, narrow scope, short lifetime, strong recovery, and complete evidence may lower it.

Transmission by a default internet-enabled workload of data within its documented readable authority is an explicit v0 non-guarantee, not by itself an Atlas vulnerability. It becomes reportable when Atlas exposes data outside that authority, bypasses a declared egress policy, leaks a source credential, or falsely reports a restriction as enforced.

### Critical

- remote compromise of the Atlas control plane or fleet update channel without prior pairing
- extraction of operator source credentials or unrestricted downstream identities
- cross-host signing or trust-root compromise that silently installs attacker code broadly
- an Atlas path that acts as a Blue or Fabric principal without explicit downstream authorization

### High

- workspace escape to host root or another workspace's source, browser profile, or grants
- pairing or relay flaws that permit durable unauthorized host control
- public exposure of a private preview containing sensitive data or privileged operations
- theft of a high-trust browser profile or reusable delegated credential
- audit bypass that makes sensitive credential use unattributable

### Medium

- denial of service requiring operator recovery but not losing durable data or credentials
- exposure of low-sensitivity workspace metadata to another paired user or workspace
- a grant lasting beyond intended expiry but retaining narrow scope and prompt revocation
- a takeover or concurrency flaw causing recoverable workspace corruption

### Low

- non-sensitive diagnostic leakage with no useful attack path
- inaccurate capability reporting that causes inconvenience but not a security-boundary failure
- activity gaps for ordinary, non-sensitive operations where security events remain intact

### Re-evaluation triggers

This model must be revisited when Atlas chooses a base OS, isolation backend, networking system, browser architecture, credential provider, update mechanism, remote service, multi-operator model, or first implementation. Each accepted architecture proposal should map its controls and residual risks back to the invariants and attacker stories above.

Repository: local-workspace:sha256:16d6a2034d722e5037122313733d30e34c06b21e3e641e77583564bec9df7191
Version: codex-security-snapshot/v1:sha256:a286c5028a680fd848057e152aff050f49dc7d757ba48d902eae4da9d1e3c447
