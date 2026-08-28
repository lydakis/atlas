# Atlas product thesis

Status: working thesis, revised August 2026

## The picture

Atlas is an operating environment for computers whose primary user is
software.

Flash it onto a physical computer that nobody plans to sit in front of. Pair
the machine once, then use Codex, Herdr, T3 Code, SSH, Blue, or another agent
interface from the devices already in your hands. Atlas makes the remote
computer safe and useful for agents without becoming the way you talk to them.

Atlas is headless, but not blind.

## The product target is a dedicated computer

The primary Atlas product is a managed image for a physical machine dedicated
mostly or entirely to agents. Owning the system can provide boot-to-ready
behavior, predictable storage, private remote access, isolation, unattended
updates, rollback, and recovery.

Virtual machines remain useful in three supporting roles:

- fast development and automated testing of the Atlas image
- an optional trial or server deployment when dedicated hardware is unavailable
- a possible internal isolation backend for higher-risk environments

Running an Atlas VM on a person's laptop for every agent is not the initial
product story. It inherits the laptop's availability, security domain, and
resource constraints, and overlaps with existing local sandbox products.

## The problem

Agent interfaces are improving quickly. They already own conversations,
projects, agent selection, terminals, diffs, task state, and human supervision.
Atlas should make those products better rather than recreate them.

The missing layer is the unattended computer beneath them. An operator still
has to assemble and maintain:

- private networking and secure remote login
- isolation between unrelated agents and identities
- browser profiles, graphical displays, observation, takeover, and recording
- safe delivery of credentials and website authority
- private access to services bound to local ports
- durable storage, resource control, updates, backups, and recovery

Each agent product either rebuilds some of that system or assumes the operator
has already done it correctly.

## Product thesis

There is room for an opinionated agent appliance beneath existing agent
products.

```text
Codex · Herdr · T3 Code · SSH · Blue · any agent client
                         │
             ordinary remote connection
                         │
    environment · volume · grant · surface · route
                         │
                   Atlas host
                         │
              dedicated physical machine
```

Atlas is not an agent harness, chat interface, IDE, model runtime, project
manager, Git workflow, or orchestration framework. It does not require an
`atlas chat`, `atlas task`, or Atlas-owned coding session.

Atlas makes three commitments:

1. **Existing tools work normally.** An agent client can treat an Atlas
   environment as an ordinary remote Linux target and retain its own project,
   worktree, terminal, and conversation model.
2. **Resettable machine state and durable data are separate.** Ordinary files,
   installed tools, home configuration, and mutable OS state live inside a
   persistent environment instance that the operator may explicitly reset.
   Repositories and other protected human data live on durable volumes that a
   reset cannot delete. Live process memory and connections are volatile.
   Browser identities, grants, routes, and resource budgets remain bound to
   enforceable Atlas resources rather than becoming ambient host state.
3. **A human can see and intervene.** Sensitive grants, browser control,
   recordings, private routes, health, updates, and recovery remain visible and
   controllable from a paired operator device.

If those commitments are not substantially better than manually combining
Linux, Tailscale, SSH, containers, browser tools, and systemd, Atlas does not
yet have a product.

## The intended product experience

Atlas is a self-hosted computer for agents: remotely configured, compatible
with any agent client, permissive inside environments, protective of
human-owned data and authority, and recoverable when agents make a mess.

The ordinary experience should be:

```text
Install Atlas on a dedicated computer or VPS
                         │
            pair a trusted phone or computer
                         │
       apply a non-secret environment declaration
                         │
          attach or synchronize owner data
                         │
          attach narrowly scoped credentials
                         │
          use Codex, Herdr, SSH, or any client
                         │
 inspect · route · observe · take over · snapshot · reset
```

The first installation offers local-only connectivity or enrollment into the
operator's tailnet. Tailscale is the first private-connectivity adapter, but it
is not the Atlas identity model. Tailnet membership makes the host reachable;
Atlas pairing determines which devices may inspect, configure, grant authority,
publish routes, operate surfaces, or perform destructive recovery actions.

A paired controller applies an inspectable, portable, non-secret declaration.
That declaration may compose templates for common toolchains, packages, Git
configuration, public variables, resource policy, volume attachments, and
network behavior. It never contains reusable credentials and never executes a
repository-carried setup script ambiently. The current NixOS configuration is
the prototype expression of this model, not the intended remote format.

A future declaration could look approximately like this:

```toml
[environment]
base = "ubuntu-24.04"

[packages]
git = "latest"
python = "3.13"
node = "24"

[git]
name = "George Lydakis"
email = "george@labblue.ai"

[variables]
NODE_ENV = "development"

[[volumes]]
name = "projects"
target = "/home/george/Developer"
```

Atlas may provide inspectable templates such as `developer`, `frontend`,
`python`, `browser-automation`, and `minimal`, plus organization-specific
templates. A template is declarative input to the same model, not an arbitrary
host-privileged setup script.

Most owners begin with one default environment. It should feel like their
machine: ordinary mutable Ubuntu, persistent across disconnect and reboot, with
the freedom to install packages, change `/etc`, run services, and use graphical
applications. Additional environments are optional boundaries for conflicting
toolchains, different authority, network policy, concurrent services, or risky
work. They are not created automatically for every agent, repository, or task.

```text
Atlas host
├── kernel, control plane, recovery, and private connectivity
├── durable human-owned volumes
└── one or more Ubuntu environments
    ├── resettable mutable root
    ├── explicitly attached owner data
    └── any number of agent applications and human-operated clients
```

Agents are applications, not owners or identities. Several agents may
intentionally share one environment and its authority. Inside it they can have
environment-local administrative freedom without receiving host control.
When isolation matters, the owner creates another environment and selectively
attaches shared read-write data, read-only data, or a future copy-on-write
volume fork.

Data safety is expressed as separate promises. A durable volume survives
environment reset. Snapshots and backups recover accidental or malicious data
changes. Encryption protects data at rest. Copy-on-write roots make machine
recovery cheap but do not make concurrent writers safe. Git, worktrees, rsync,
and existing synchronization tools remain ordinary ways to move and coordinate
files; Atlas supplies lifecycle and authority boundaries rather than inventing
a project model.

"My data is safe" therefore expands into several independently testable
questions:

- does it survive environment reset?
- can it be recovered after accidental deletion or corruption?
- can an environment with read access modify it?
- can one malicious environment reach another owner's data?
- can it be recovered after disk or machine loss?
- is it private if the physical computer or VPS account is compromised?

The volume model should eventually expose at least three attachment modes:

1. **Shared read-write:** cooperating environments deliberately manipulate the
   same files.
2. **Read-only:** an environment may inspect data but cannot modify it.
3. **Copy-on-write fork:** an environment receives an inexpensive private view
   that the owner later adopts, merges, or discards.

For source code, separate checkouts or Git worktrees may be safer than several
independent agents mutating one working directory. Atlas provides the storage
and isolation mechanisms; the selected client and Git retain checkout and merge
semantics.

Configuration and authority remain distinct. Packages, Git name and email,
tool versions, and non-secret variables belong to environment configuration.
API keys, SSH authority, cloud sessions, and authenticated browser identities
are grants. A paired operator attaches those grants deliberately to an
environment or, when Atlas can enforce a narrower boundary, to a shorter-lived
invocation. Brokered operations and short-lived derivatives are preferred over
copying reusable source credentials into the environment.

The separation is:

1. **Configuration:** packages, tool versions, public variables, Git name and
   email, and resource policy.
2. **Owner data:** repositories, artifacts, datasets, worktrees, and
   uncommitted work.
3. **Grants:** API keys, SSH authority, cloud sessions, GitHub credentials, and
   authenticated browser identities.

The paired operator should be able to say, for example, "allow this environment
to use my GitHub push authority and this OpenAI key until revoked." A brokered
credential is preferable when the underlying protocol allows Atlas to perform
the narrow operation without delivering a reusable source credential.

### Private reachability and pairing

The first-boot choice should be understandable without Atlas vocabulary:

```text
Choose connectivity

○ Local only
● Join my Tailscale network
○ Configure later
```

Interactive Tailscale enrollment can display a login URL and QR code. Automated
installation can consume a short-lived, scoped auth key from a runtime secret,
never from the image or portable environment declaration. A controller already
on the tailnet then reaches Atlas through its private address or name.

Three authorities remain separate:

- **Tailscale membership** makes the Atlas host reachable.
- **Atlas pairing** identifies a trusted operator device.
- **Atlas policy** decides whether that device may inspect, configure, attach
  grants, publish routes, operate surfaces, snapshot, reset, or recover.

Local-only use applies the same Atlas pairing and authorization model without a
tailnet. Tailscale is the preferred transport, not a mandatory Atlas cloud or a
substitute for Atlas authorization.

The administrative CLI and operator interface control the machine; they do not
replace agent clients. An illustrative future flow is:

```text
atlas pair
atlas apply -f developer.toml
atlas enter default
atlas volume sync projects ./Developer
atlas grant attach default github-work
atlas route publish default 3000
atlas surface open default --app ./my-app
atlas snapshot create default before-upgrade
atlas reset default
```

The same paired-device protocol should support a phone. A phone is especially
useful for approving grants, completing authentication, viewing screenshots or
recordings, briefly taking over a surface, revoking access, and performing an
emergency stop. A laptop remains more convenient for editing declarations and
extended terminal work.

The product experience can be similar on owned hardware and a VPS, but the
security promise differs. On owned hardware Atlas may control disk encryption,
boot integrity, recovery media, and physical access assumptions. A VPS provider
controls the hypervisor and may be able to inspect disk or memory. Atlas can
still provide environment isolation and recovery there, but it cannot protect
the owner from the infrastructure provider.

The first product is intentionally single-owner: one human, one normal default
environment, several concurrent agent applications, and optional additional
environments. Multi-human operation remains possible later, but introduces
volume ownership, environment membership, grant ownership, approval policy,
audit attribution, and administrator roles. It is a separate security and
product milestone, not another Unix account added to v0.

The first compelling end-to-end milestone is:

> Install Atlas, pair a laptop, apply a developer environment, connect with
> Herdr or Codex, clone a repository onto durable storage, run multiple agents,
> expose a private preview, and confidently reset the environment without
> losing the work.

That proof should include this concrete sequence:

1. Declare a default environment with Git, Python, non-secret variables, and a
   Git identity.
2. Attach the owner's project volume and enter through an existing client.
3. Clone a repository, create uncommitted work, install a package, and modify
   `/etc`.
4. Let several agent processes use the same environment concurrently.
5. Reboot and prove persistent machine state and owner data remain.
6. Snapshot the root, change it, restore it, and prove owner data was not rolled
   back with machine state.
7. Reset the environment and prove installed packages and resettable changes
   disappeared while the repository and uncommitted work survived.
8. Create a second environment, run the same loopback port in both, and prove
   their networks do not collide or cross.
9. Publish one selected port privately to the paired device.
10. Start one graphical application surface, let an agent operate and record
    it, then let the owner observe and take over from the paired device.

### Headless, not blind

Agents sometimes need pixels, pointer input, keyboards, browsers, and graphical
applications even when no human will sit in front of the machine. Atlas should
let an environment create a bounded graphical surface, usually a lightweight
virtual display containing one application rather than a conventional desktop.
The agent can inspect and operate it, take screenshots, record a demonstration,
test a graphical build, and retain selected output as an artifact. A complete
desktop remains an opt-in escape hatch.

```text
Environment
├── processes
├── network
├── resettable root
├── attached volumes
├── grants
└── surfaces
    ├── browser
    ├── single graphical application
    ├── optional desktop
    └── terminal or graphical recording
```

The default graphical presentation could be deliberately simple:

```text
┌──────────────────────────────────────────┐
│ Atlas · default · application-name       │
├──────────────────────────────────────────┤
│                                          │
│             Application UI               │
│                                          │
└──────────────────────────────────────────┘
```

Underneath, a minimal virtual Wayland compositor can host one application, with
XWayland compatibility where needed. The environment believes it has a normal
display even though no physical screen is attached.

An agent should be able to:

- take screenshots
- inspect accessibility information
- move the pointer and type
- navigate browser pages
- launch and test graphical development builds
- record a short demonstration
- produce screenshots or videos as durable artifacts
- leave a surface available for later inspection

Terminal capture is a related artifact rather than a graphical surface. Tools
such as asciinema can preserve a command transcript while graphical recording
preserves pixels, input transitions, and selected application metadata.

The owner does not need to discover the right window through a permanent VNC
desktop. Atlas presents the relevant application directly on a paired device.
The owner may observe it, take exclusive control, return control to the agent,
or destroy it. Raw VNC, RDP, or browser-debug endpoints may be compatibility
transports, but they are not the authorization boundary and are never published
merely because they exist.

The intended takeover experience is not "connect to VNC and find the right
window." It is "the agent needs you to authenticate; open this surface."

1. Atlas pauses agent input and observation for that surface.
2. The operator sees broker-owned chrome naming the host, environment,
   application, browser identity, and destination.
3. The operator takes exclusive control on a paired device.
4. Sensitive input is excluded from agent context, recording, clipboard
   observation, and audit payloads where the boundary can enforce that claim.
5. The operator explicitly returns control to the agent.
6. Atlas records the authority transition without recording the secret.

A host-owned surface broker authenticates viewers, enforces the controller
state, and carries the stream over an end-to-end-protected paired-device
channel. WebRTC may provide the primary interactive transport. VNC or RDP can
remain compatibility options behind the same broker rather than permanent
network listeners.

Generic environment-owned surfaces and protected browser surfaces have
different trust. An ordinary graphical application or disposable browser may
run entirely inside the environment. A valuable authenticated browser identity
must keep its profile, cookies, automation endpoint, display, and operator-input
path outside the environment. During authentication Atlas fences agent input
and observation, shows broker-owned context to the operator, accepts protected
human input, and returns bounded control only after the takeover transition is
complete. The detailed boundary is defined by
[Authenticated Surface v0](authenticated-surface-v0.md).

The two browser trust levels should be explicit:

**Environment-owned browser**

- runs completely inside Ubuntu
- gives the environment effective access to its profile and cookies
- fits testing, scraping, disposable identities, and low-risk accounts
- can be discarded with environment state

**Protected Atlas browser**

- keeps its profile and session authority outside the environment
- exposes a bounded observation and action interface through the surface broker
- lets the human authenticate through a protected takeover path
- fits valuable persistent identities where raw profile access is unacceptable

No polished login handoff can protect cookies that live inside an environment
where the agent has administrative authority. Valuable browser identities
require the separate host-controlled worker boundary.

The machine primitives compose without collapsing into one remote-desktop
feature:

| Primitive | Purpose |
| --- | --- |
| Host | Own the machine, control plane, updates, recovery, and connectivity |
| Environment | Provide a reusable Linux filesystem, process, authority, resource, and network boundary |
| Volume | Hold human-owned durable data independently of environment reset |
| Grant | Supply a credential or delegated authority deliberately and revocably |
| Route | Make one selected TCP or HTTP service privately reachable |
| Surface | Carry pixels and input for one graphical application or browser |
| Recording | Retain selected terminal or graphical evidence as an artifact |

A browser login may compose an Environment, Grant, Surface, and Route, but none
silently creates another. Detecting a port does not publish it. Creating a
surface does not attach credentials. Attaching a grant does not expose a
service. This separation is the basis of Atlas's machine-level security model.

## Core primitives

Atlas exposes six host-level primitives.

### Host

A physical Atlas computer with a hardware and software identity, declared
capabilities, health state, private connectivity, update lineage, and recovery
path.

### Environment

A named, reusable execution and trust context realized as a Linux compartment.
It is the target an existing agent tool selects or enters before work begins.
An environment owns an enforceable OS principal, resettable root filesystem and
home, process and resource boundaries, network context, and non-secret
configuration. Atlas binds grants, surfaces, routes, and activity to the
environment's opaque identity.

An environment instance is mutable, persistent, and resettable. Tools installed
by an agent, caches, ordinary files, and changes under its root or home should
survive re-entry, environment restart, host reboot, and supported update. An
explicit reset reconstructs that machine state from its declared seed. Resetting
the instance must not destroy an attached durable volume.

Volatile execution state is narrower: process memory, open connections, sockets,
locks, PID files, `/run`, and connection-local terminal state do not survive a
normal reboot. Declared services may restart from persistent files, but Atlas
does not promise transparent process checkpointing. Deliberately ephemeral
environments may be offered later as an explicit policy; they are not the
default agent experience.

An environment may define non-secret configuration. Secret values are not part
of that configuration. Source credentials remain in an operator-owned or Atlas
control-plane store by default; an explicitly approved materialized-secret grant
is the degraded exception. Grants bind specific authority to the environment
through an explicit delivery mode.

Environment definitions may compose reusable non-secret layers into a named or
explicitly ephemeral instance. Projects and agents select an environment; Atlas
does not
assign environments to projects. Several agents may use one environment when
they intentionally share its execution state and authority context. The
detailed entry contract is defined by
[Environment Entry v0](environment-entry-v0.md).

An environment is not a repository or task. Codex, Herdr, T3 Code, Git, or the
operator may clone repositories, create worktrees, run terminals, and manage
projects and sessions inside it. Atlas should only add repository or session
primitives later if a specific host-level guarantee cannot be supplied by those
tools.

The normal product experience begins with one default environment. Additional
environments are explicit boundaries for different authority, network policy,
incompatible toolchains, reset policy, or resource limits, not a requirement per
project, repository, agent, or conversation.

### Volume

Durable operator-owned data attached explicitly to one or more environments at
a declared path and access mode. Repositories, worktrees, datasets, artifacts,
and other files that must outlive an environment instance belong on volumes.

A volume is not a container home and does not inherit an environment's
lifecycle. Resetting or replacing an environment leaves its attached volumes
intact. Multiple cooperating environments may mount one volume read-write; an
inspection environment may receive it read-only. Copy-on-write forks and
per-human ownership are later lifecycle and policy features of the same
primitive.

### Grant

Operator-approved authority made available to one environment for a defined
audience, operation set, and lifetime. A grant may deliver a short-lived token,
mediate a protocol operation, or authorize use of a browser identity. It is not
a copy of the operator's password vault.

### Surface

A browser, graphical application, or optional desktop that an agent can operate
and an operator can observe, record, or take over. The default product surface
is a bounded single-application virtual display, not a permanent full desktop.
Browser profiles, cookies, screenshots, recordings, clipboard state, and
downloads are sensitive Atlas-managed state bound to an environment, not files
owned by that environment.

### Route

Private, authenticated access from a paired device to a service listening
inside an environment. Detecting a port does not publish it. Public sharing is
a separate, explicit, expiring grant.

These are machine resources beneath client concepts. Atlas does not try to map
them onto every client's conversations, panes, threads, or tasks.

## Existing-client independence has a mechanism

Atlas cannot enforce isolation or credential policy around a process it cannot
identify. Existing-tool compatibility therefore needs an environment entry
boundary, but not an Atlas coding workflow.

The baseline entry can be conventional:

- an SSH target and Linux login that lands inside an environment
- a remote-development target exposed by an existing client
- a login shell or process launcher supplied by the environment
- a small adapter when a client supports richer host integrations

After entry, the tool behaves normally. A direct host-root shell or unmanaged
host process receives no environment isolation or grant guarantees.

Atlas-aware clients may consume structured interfaces for approvals, browser
attachment, routes, health, and activity. Compatibility cannot require a
conversation plugin for any particular client.

## The first distinctive use case

The first product proof is an existing agent client using durable code and a
persistent, observable browser identity on a physical Atlas machine.

1. Flash Atlas onto a representative spare computer.
2. Enroll it into the operator's private network and connect using SSH.
3. Attach a durable project volume and enter one agent environment with an
   existing agent tool.
4. Let the agent install a tool and modify its resettable operating system,
   then reset the environment and prove the project volume survived.
5. Start an isolated browser surface with one low-risk test identity.
6. Let the operator authenticate that browser once without copying a password
   into the environment.
7. Let the agent operate the authenticated site through a bounded computer-use
   interface.
8. Let the operator watch, record, take over, and return control.
9. Expose one development server through a tailnet-private route.
10. Create a restricted environment without the project volume and prove it
    cannot access the first environment's resettable state, durable volume,
    profile, grants, surface, or route.
11. Reboot or update the host, preserve resettable environment files, and
    preserve the state declared durable.

This does not begin with the operator's primary personal identity. It begins
with a disposable or low-risk account so that Atlas can prove its boundary
before being trusted with consequential authority.

## Credential model

Atlas distinguishes three delivery modes.

1. **Materialized runtime secret:** a source or derivative token, password,
   file, or environment variable is copied into the environment. Its processes
   can read and exfiltrate it, so Atlas always reports this as degraded and says
   whether the value is a source credential or scoped derivative.
2. **Derived or brokered authority:** Atlas or a local helper performs a narrow
   operation or produces a short-lived derivative credential without exposing
   the source secret. Git credential helpers, SSH agents, cloud session
   credentials, and request-signing proxies can fit this model.
3. **Browser identity:** session credentials remain in a protected browser
   profile while the environment receives permission to operate a browser
   surface.

An environment is the default authority boundary. Unless Atlas can prove a
narrower process identity and confinement boundary, every process inside one
environment must be treated as capable of using its runtime authority. Agent
instances that require different authority sets belong in separate
environments.

Browser control is authority, even when the agent never receives the original
password. An agent controlling a logged-in browser can act as that user. Raw
browser-debug protocols may also expose cookies, so higher-trust identities may
require a narrower screenshot-and-action interface rather than unrestricted
debug access.

Atlas should create separate browser identities by purpose and trust level. It
should not synchronize a person's complete browser profile or password vault
onto an autonomous machine.

## Code and parallelism

Atlas isolates environments, not Git strategies.

On an attached volume, the selected agent tool may use ordinary clones,
worktrees, branches, or its own project model. Several cooperating environments
may deliberately share that volume, but Atlas does not prevent Git-level races
or make concurrent writers safe. Git worktrees share repository metadata and
therefore require a shared trust boundary. Stronger isolation may use separate
volumes, clones, or copy-on-write volume forks, with immutable object caches
where safe.

Atlas should add an opinionated checkout or fork operation only after evidence
shows that existing tools cannot provide the required isolation, recovery, or
movement semantics.

## Connectivity

The first connectivity adapter is Tailscale because it provides stable private
reachability across changing networks. The intended baseline is:

- no publicly reachable administrative port by default
- enrollment using a short-lived or interactive ceremony
- SSH over the tailnet, with authorization controlled by tailnet policy
- private routes reachable only by authorized tailnet identities
- local or console recovery that does not depend on an Atlas cloud

Tailscale is an adapter, not the Atlas identity model. Tailnet membership gives
network reachability; Atlas still authorizes environments, grants, surfaces,
routes, and host operations.

The core machine must remain useful without an Atlas-operated cloud service.
Optional rendezvous, relays, public sharing, update mirrors, and off-host audit
storage must be explicit and replaceable where practical.

## Operator surface

The Atlas CLI is an administrative and automation surface, not the daily agent
experience. It may support pairing, conformance checks, environment lifecycle,
grants, browser observation, routes, updates, backup, and recovery.

A small operator web interface may be more appropriate for approvals, browser
takeover, recordings, and use from a phone. It remains an operating console,
not another agent client.

## Image and supported install

The managed image is the product destination. A supported Linux installation
may expose the same primitives for adoption and comparison, but it cannot claim
the same boot, drift, storage, update, or recovery guarantees unless the host
satisfies them.

NixOS is the current prototype vehicle because the completed spike validates a
pinned host declaration, mutable state outside the Nix store, system resource
separation, and generation rollback. It is not a permanent product decision.
Virtual machines continue to exercise the image in development and CI while
the next product proof runs on representative physical hardware.

The bootc comparison should occur after the environment, surface, grant, and
route contract is concrete enough to port. The comparison should test the same
product behavior rather than choose a base from image mechanics alone.

## Delivery sequence

1. **Physical host:** persistent installation, private enrollment, SSH,
   encrypted state with a declared unlock mode, update, and recovery.
2. **Environment:** one resettable Linux compartment that an existing agent
   client can use as a normal remote target and mutate as root without gaining
   host root.
3. **Volume:** durable project data that survives environment reset, reboot,
   update, and recovery according to declared policy.
4. **Surface:** one isolated browser profile with observation, recording, and
   exclusive takeover.
5. **Grant:** authenticate one low-risk browser identity, then add one narrow
   brokered service credential.
6. **Route:** expose one environment service privately through the tailnet.
7. **Isolation proof:** demonstrate that a second environment cannot cross any
   unmounted volume, process, profile, grant, surface, route, or resource
   boundary.
8. **Reconstruction:** reboot and update without losing state declared durable.

The [Authenticated Surface v0](authenticated-surface-v0.md) contract supplies
the security boundary for the environment, surface, and browser-grant steps
inside this end-to-end proof. It stores an isolated authenticated browser
session rather than importing the operator's password vault.

## First proof

Atlas v0 succeeds when:

1. A supported physical machine can be flashed, enrolled, and reached without
   a permanently attached display.
2. SSH and private routes are unavailable from the public network by default.
3. An existing agent interface uses an environment without adopting an Atlas
   conversation, project, terminal, or Git model.
4. Two environments have kernel-enforced identities, resettable private OS
   state, separate process and resource boundaries, and attributable activity.
5. One browser identity remains unavailable to every environment except the
   one holding its grant.
6. An agent uses the browser while the operator can observe, take over, record,
   and revoke access.
7. The operator source password used for the browser proof is never placed in
   the environment, browser password storage, or Nix store.
8. One service becomes reachable through an explicit private route without a
   public listener or manual port forwarding.
9. Reset destroys one environment's installed tools and mutable OS state while
   preserving its attached durable volume.
10. Reboot and update preserve resettable environment files and documented
    durable state.
11. `atlas doctor` reports which guarantees the machine actually satisfies.

## Boundaries

Atlas initially does not:

- replace Codex, Herdr, T3 Code, SSH, Blue, or another agent client
- define conversations, prompts, tasks, models, repositories, or worktrees
- require a particular model provider or agent subscription
- synchronize a personal password vault or primary browser profile
- claim that an agent with authorized browser control is harmless
- give environments arbitrary root access to the host control plane
- prevent an internet-enabled environment from disclosing data it is allowed
  to read
- compete as a hyperscale sandbox cloud
- promise arbitrary live-process migration or process-memory persistence
- make Atlas itself the principal in downstream systems

## Blue reuse

Blue may treat an Atlas environment as an execution destination and consume
grants, surfaces, routes, health, and activity interfaces. Atlas owns
machine-local enforcement. Blue retains execution profiles, route
authorization, claims, leases, fencing, and Fabric-facing identity. Hosting a
Blue process never authorizes Atlas to act as that process or principal.

## Kill tests

Atlas should be reconsidered if:

- existing clients require Atlas-specific conversation or project integrations
  before the host is useful
- the environment is indistinguishable from an ordinary Linux account or
  manually configured container
- browser identity isolation cannot prevent cross-environment profile access
- observation and takeover are not materially safer or easier than existing
  remote-desktop and browser tools
- owning the OS does not create measurable security, reliability, or recovery
  advantages

## Strategic test

Atlas is worth continuing if people with dedicated or underused computers turn
them into Atlas hosts instead of manually administering another Linux server,
while continuing to use the agent interfaces they already prefer.

The short promise is:

> Turn a computer nobody will sit in front of into a complete, observable
> computer for agents.
