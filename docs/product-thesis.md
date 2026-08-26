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
       environment · grant · surface · route
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
2. **Authority is compartmentalized.** Files, processes, browser identities,
   credentials, routes, and resource budgets belong to an enforceable
   environment rather than becoming ambient host state.
3. **A human can see and intervene.** Sensitive grants, browser control,
   recordings, private routes, health, updates, and recovery remain visible and
   controllable from a paired operator device.

If those commitments are not substantially better than manually combining
Linux, Tailscale, SSH, containers, browser tools, and systemd, Atlas does not
yet have a product.

## Core primitives

Atlas exposes five host-level primitives.

### Host

A physical Atlas computer with a hardware and software identity, declared
capabilities, health state, private connectivity, update lineage, and recovery
path.

### Environment

A persistent Linux compartment into which an existing agent tool connects. An
environment owns an enforceable OS principal, files, process and resource
boundaries, network context, browser identities, grants, surfaces, routes, and
activity.

An environment is not a repository or task. Codex, Herdr, T3 Code, Git, or the
operator may clone repositories, create worktrees, run terminals, and manage
projects inside it. Atlas should only add repository primitives later if a
specific host-level guarantee cannot be supplied by those tools.

### Grant

Operator-approved authority made available to one environment for a defined
audience, operation set, and lifetime. A grant may deliver a short-lived token,
mediate a protocol operation, or authorize use of a browser identity. It is not
a copy of the operator's password vault.

### Surface

A browser or graphical desktop that an agent can operate and an operator can
observe, record, or take over. Browser profiles, cookies, screenshots,
recordings, clipboard state, and downloads are sensitive environment state.

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

The first product proof is an existing agent client using a persistent,
observable browser identity on a physical Atlas machine.

1. Flash Atlas onto a representative spare computer.
2. Enroll it into the operator's private network and connect using SSH.
3. Enter one persistent agent environment with an existing agent tool.
4. Start an isolated browser surface with one low-risk test identity.
5. Let the operator authenticate that browser once without copying a password
   into the environment.
6. Let the agent operate the authenticated site through a bounded computer-use
   interface.
7. Let the operator watch, record, take over, and return control.
8. Expose one development server through a tailnet-private route.
9. Create a second environment and prove it cannot access the first
   environment's files, processes, profile, grants, surface, or route.
10. Reboot or update the host and preserve the state declared durable.

This does not begin with the operator's primary personal identity. It begins
with a disposable or low-risk account so that Atlas can prove its boundary
before being trusted with consequential authority.

## Credential model

Atlas distinguishes three forms of access.

1. **Materialized secret:** a token or password is delivered to a process. The
   process can read and exfiltrate it, so this is a documented degraded mode.
2. **Brokered operation:** Atlas or a local helper performs a narrow operation
   or produces a short-lived derivative credential without exposing the source
   secret. Git credential helpers, SSH agents, cloud session credentials, and
   request-signing proxies can fit this model.
3. **Browser identity:** session credentials remain in a protected browser
   profile while an agent receives permission to operate a browser surface.

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

Inside one environment, the selected agent tool may use ordinary clones,
worktrees, branches, or its own project model. Separate environments require
separate writable state. Git worktrees share repository metadata and therefore
belong inside one trust boundary. Stronger isolation may use separate clones or
copy-on-write filesystem snapshots, with immutable object caches where safe.

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
   encrypted state design, update, and recovery.
2. **Environment:** one enforceable Linux compartment that an existing agent
   client can use as a normal remote target.
3. **Surface:** one isolated browser profile with observation, recording, and
   exclusive takeover.
4. **Grant:** authenticate one low-risk browser identity, then add one narrow
   brokered service credential.
5. **Route:** expose one environment service privately through the tailnet.
6. **Isolation proof:** demonstrate that a second environment cannot cross any
   file, process, profile, grant, surface, route, or resource boundary.
7. **Reconstruction:** reboot and update without losing state declared durable.

## First proof

Atlas v0 succeeds when:

1. A supported physical machine can be flashed, enrolled, and reached without
   a permanently attached display.
2. SSH and private routes are unavailable from the public network by default.
3. An existing agent interface uses an environment without adopting an Atlas
   conversation, project, terminal, or Git model.
4. Two environments have kernel-enforced identities, private writable state,
   separate process and resource boundaries, and attributable activity.
5. One browser identity remains unavailable to every environment except the
   one holding its grant.
6. An agent uses the browser while the operator can observe, take over, record,
   and revoke access.
7. Raw source credentials are never placed in the environment or Nix store.
8. One service becomes reachable through an explicit private route without a
   public listener or manual port forwarding.
9. Reboot and update preserve or deliberately reconstruct documented durable
   state.
10. `atlas doctor` reports which guarantees the machine actually satisfies.

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
