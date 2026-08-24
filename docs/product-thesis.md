# Atlas product thesis

Status: working thesis, August 2026

## The picture

Atlas is an operating environment for computers whose primary user is software.

Install it on a physical machine or VM that nobody needs to sit in front of. The machine becomes a dependable place where agents can write and run code, use websites and graphical applications, expose what they build, and continue working after every client disconnects. A human remains the operator and can inspect, approve, intervene, or take control.

Atlas is headless, but not blind.

## The problem

Giving an agent a remote shell is easy. Giving it a complete, durable, observable computer is not.

Today an operator must assemble Linux, SSH, private networking, persistent sessions, workspaces, containers, browsers, virtual displays, port forwarding, credentials, audit, updates, backups, and recovery. Each agent interface either rebuilds part of this stack or assumes somebody else already did.

T3 Code, Herdr, the Codex app, agent CLIs, and products such as Blue solve a different problem. They determine how people launch, supervise, and communicate with agents. They should not each have to turn an arbitrary computer into a safe and dependable agent host.

Atlas supplies that missing computer layer.

## Who it is for first

The first operator owns or administers one to five physical or virtual machines dedicated primarily to agents. They want to use their existing agent interfaces, keep control of the hardware and data, and avoid becoming the systems integrator for every machine.

This is a product for a general class of dedicated compute, not for one person's current collection of devices.

## Product thesis

There is room for an opinionated host environment beneath agent products.

Atlas is not an agent harness, chat interface, IDE, model runtime, or orchestration framework. It provides reattachable terminal-session primitives where required, but does not own the terminal or conversation experience. It is the machine layer beneath those products:

```text
Codex app · T3 Code · Herdr · SSH · Blue · any agent CLI
                         │
              stable local host contract
                         │
     workspace · workload · preview · browser · identity
                         │
          Atlas image or supported Linux install
                         │
                physical machine or VM
```

Atlas makes three commitments:

1. **Durable, attributable work.** An agent gets an isolated workspace and workload identity that survives client disconnection and can be inspected or recovered.
2. **Visible, reachable results.** Services, browsers, and graphical surfaces are private by default and easy for an operator to open, observe, and take over.
3. **Scoped access with evidence.** Agents receive explicit, limited capabilities instead of ambient host secrets, and important use is attributable and reviewable.

If these commitments are not substantially better than configuring an ordinary Linux server, Atlas does not yet have a product.

The core abstraction is the complete execution context of an agent:

```text
execution context =
  workspace branch
  + supervised workload
  + resource envelope
  + network boundary
  + terminal, browser, and display surfaces
  + delegated grants
  + attributable event stream
```

Atlas makes that context a first-class host resource that can be created, attached to, forked, constrained, observed, checkpointed, reconstructed, moved, and destroyed. The client still decides what the agent does.

## Interface independence has a mechanism

Atlas integrates at the agent process inside the machine, not at the client conversation.

Every agent interface eventually starts a process in a workspace. Inside that workspace, Atlas exposes ordinary and versioned machine-local interfaces:

- an `atlas` CLI on `PATH`, with stable human output and machine-readable JSON
- an MCP adapter for clients and agents that support MCP
- a local authenticated API over a Unix socket for richer integrations
- conventional environment, filesystem, credential-helper, port, and process behavior for tools with no Atlas awareness

Every managed process must cross an Atlas launch boundary, such as an Atlas-owned workspace shell or a stable `atlas workload run` entrypoint. Interface independence means that a client does not need an Atlas-specific conversation plugin. It does not mean an arbitrary unmanaged process is retroactively given an Atlas identity.

The host derives identity from kernel-enforced workspace and workload boundaries. It does not trust a process to declare which agent or workspace it is.

This means a shell-compatible agent can benefit without a custom Atlas plugin. An Atlas-aware client can add richer previews, approvals, activity, browser attachment, and lifecycle controls without becoming the only way to use the machine.

T3 Code may own its projects, threads, terminals, diffs, and mobile experience. Herdr may own its sessions, panes, and agent status. The Codex app may own its task experience. Blue may treat Atlas as an execution destination. Atlas owns the machine-local resources beneath those experiences.

The Atlas CLI manages and inspects the machine. The same binary can expose different methods according to the caller's proven role. A workload can request authority but cannot approve its own request:

```bash
# inside a workload
atlas inspect
atlas preview request --port 3000
atlas credential request github --scope repo:read

# from a paired operator device
atlas host list
atlas workspace inspect blue
atlas preview open blue
atlas browser attach blue
atlas grant approve blue github
atlas activity blue
```

There should not need to be an `atlas chat`.

## The initial product nucleus

Atlas should first make one workflow unusually complete:

1. Provision or install a supported Linux host and pair it securely.
2. Start an unmodified agent through the Atlas launch boundary from any shell-compatible interface.
3. Let an Atlas-supervised workload and its reattachable terminal continue independently of the client connection.
4. Discover a development port automatically and turn it into a private authenticated URL through explicit policy or action.
5. Let the agent use an isolated browser that the operator can watch and take over.
6. Delegate one narrowly scoped service identity without exposing the operator's ambient credentials.
7. Show the operator what ran, changed, connected, and used that identity.
8. Reboot or update the host without losing declared durable state.

This nucleus is deliberately narrower than the eventual platform. Terminal persistence alone is not enough. Browser automation alone is not enough. The product is the coherent boundary around work, surfaces, access, and operator control.

## The longer capability map

The initial nucleus can grow into six capability families:

- **Code:** durable workspaces, snapshots, forks, recovery, and movement of files, repository state, and declared workload metadata between hosts
- **Compute:** supervised process trees, resource accounting, isolation, persistent services, disposable jobs, and optional container or VM backends
- **Interaction:** terminal sessions, isolated browsers, virtual displays, graphical application streaming, and explicit human takeover
- **Preview:** automatic service discovery, private authenticated URLs, controlled public sharing, screenshots, recordings, and live views
- **Identity:** delegated credentials, trust-separated browser profiles, approvals, attribution, revocation, and audit history
- **Connectivity:** secure pairing, private mesh access, reconnection, recovery SSH, and access from computers, tablets, and phones

State movement means reconstructing declared work from durable files and metadata. It does not mean transparent migration of arbitrary live processes.

## State parallelism

Parallel agents are primarily a state-isolation problem, not a CPU-scheduling problem. They collide through shared checkouts, ports, package caches, databases, browser profiles, credentials, generated files, and abandoned processes.

Atlas should make workspace branching cheap and coherent:

```bash
atlas workspace fork project --count 8
```

The result is eight workspace branches with independent writer ownership, workload trees, port namespaces, browser state, grants, resource budgets, and event streams. Shared toolchains and caches may be reused only through immutable or brokered mechanisms that prevent one workspace from poisoning another.

Atlas provides these execution contexts. It does not choose models, prompts, tasks, or how many agents a client should launch. A harness can request eight branches and place an agent in each; Atlas returns attributable branches, outputs, and candidate changes rather than becoming the harness itself.

Fork and explicit merge are preferred to a shared multi-writer filesystem. Moving a branch between hosts transfers a checkpoint and writer lease, not a live process image.

## Image and installer

Atlas has one capability core and two delivery paths.

The **managed image** is the product destination for a machine dedicated to agents. Controlling the system can provide boot-to-ready behavior, a known storage layout, unattended service supervision, workload isolation, update rollback, drift resistance, and predictable recovery.

The **supported Linux install** is the adoption and validation path for an existing server, VM, or development machine. It should expose the same local contract, but some guarantees depend on the underlying host.

`atlas doctor` should report capability conformance and missing guarantees. A client should not need a separate integration for each delivery path.

```text
Managed image                     Supported Linux
─────────────                     ───────────────
same capability core             same capability core
boot-to-ready appliance           package or installer
managed security baseline         inspected host baseline
atomic recovery target            host-dependent recovery
strong drift guarantees           explicit conformance gaps
```

The installer or VM is likely the fastest way to validate the architecture. The image remains strategically important only where owning the full OS produces measurable reliability, security, or recovery benefits.

An installer can provide capabilities. A managed image can guarantee invariants. On the managed image, every process that receives Atlas workspace capabilities must enter through the workload boundary, control-plane resources must remain available under pressure, and storage, updates, rollback, and recovery must follow a known design.

The base distribution, image technology, update model, and isolation backend are intentionally undecided. Atlas should build on established kernel and distribution mechanisms rather than inventing them.

The first architecture spike uses NixOS because a pinned system declaration, buildable VM and ISO outputs, and generation rollback directly test the managed-image thesis. NixOS is the leading candidate after that spike, not a product commitment. Atlas should retain it only if the next proofs show that declarative host policy produces a materially safer and more recoverable appliance than an OCI image-based alternative such as bootc.

## Operator surface

Atlas does not need its own agent conversation UI. It does need a small operator surface for actions that do not fit safely in a terminal alone: pairing, approvals, browser and display takeover, recovery, and perhaps live activity.

That surface may be a local web application used through the private network. It is an operating console, not another agent client.

## Identity boundary

Atlas is a trusted host and credential broker. It authenticates the local workspace, enforces the operator's grant, and delivers the resulting capability to that workload.

Atlas must not silently become the downstream principal. A service identity belongs to the operator, workspace, agent, or product that was explicitly authorized. Atlas cannot infer that hosting a process authorizes Atlas itself to act as that process.

Credentials should be short-lived, scoped, revocable, and absent from the workspace until requested. Browser cookies and profiles are credentials and require the same rigor.

## Cloud boundary

The core machine must remain useful without an Atlas-operated cloud service. Local workspaces, supervision, private-network access, previews, browser control, credential brokering, audit, updates, and recovery need local or self-hostable paths.

Optional hosted rendezvous, relays, update mirrors, public preview sharing, and off-host audit storage may improve the product. They must be explicit dependencies, replaceable where practical, and unable to turn a disconnected Atlas host into a useless computer.

## Delivery sequence

The first proof is one continuous story, but it should be built in narrow layers:

1. **Durability and visibility:** pair one host, create an isolated workspace, launch through the Atlas entrypoint, reattach to its terminal, and publish one private preview.
2. **Visual interaction:** add one ephemeral browser profile with observation, an exclusive takeover lease, and clear return of control.
3. **One delegated identity:** support one downstream service with narrow derivative credentials and prove request, approval, use attribution where observable, expiry, denial, and revocation.
4. **Reconstruction:** reboot and reconstruct documented workspaces, declared services, private routes, persistent profiles, and activity state.
5. **State parallelism:** fork one workspace into independently writable branches and prove that workloads do not collide through files, processes, ports, browsers, grants, or resource budgets.

MCP, public sharing, broad graphical application support, cross-host movement, multiple operators, universal credential brokering, and a custom image can wait until the relevant layer is compelling.

## First proof

Atlas v0 succeeds when a fresh supported Linux machine or VM demonstrates all of the following:

1. Installation and secure pairing take less than ten minutes.
2. Two independent agent interfaces launch through the same host contract, including one Atlas does not control.
3. An Atlas-owned terminal and workload continue across client disconnects and can be reattached without tying lifetime to either client.
4. Separate workspaces have kernel-enforced identities, resource boundaries, and attributable activity.
5. A discovered development service becomes privately reachable after explicit policy or action, without manual port forwarding.
6. An agent controls an isolated browser that the operator can observe and take over.
7. One short-lived, scoped credential can be granted, used, audited, and revoked without exposing the operator's source credential.
8. Reboot and update preserve or deliberately reconstruct all documented durable state.
9. `atlas doctor` explains which guarantees the host satisfies and which it cannot.
10. A workspace can be forked into two independently writable branches whose workloads can use the same local port without filesystem, process, browser, grant, or routing collisions.

The proof can begin as an installer or VM. It should not claim appliance-grade guarantees until those guarantees are tested on an owned image.

## Boundaries

Atlas initially does not:

- replace T3 Code, Herdr, the Codex app, agent CLIs, or Blue
- define how an agent thinks, plans, remembers, or communicates
- require a particular model provider or subscription
- synchronize a personal password vault onto an autonomous machine
- give agent workloads arbitrary root access to the host control plane
- expose every host customization at the cost of reproducibility
- compete as a hyperscale sandbox cloud
- promise arbitrary live process migration or perfect checkpointing
- prevent an internet-enabled workload from disclosing data it is legitimately allowed to read in its own workspace
- make Atlas itself the principal in downstream systems

## Blue reuse

Atlas remains product-neutral. Blue may treat an Atlas host as an execution destination and consume its workspace, workload, preview, browser, display, identity-broker, and activity interfaces.

Atlas owns machine-local execution mechanics. Blue continues to own its execution profiles, route authorization, claims, leases, fencing, and Fabric-facing identity. Hosting a Blue process never authorizes Atlas to act as that process or principal.

## Kill tests

Atlas should be reconsidered if any of these remain true after the first proof:

- the useful experience is indistinguishable from a documented bundle of SSH, systemd, containers, Tailscale, and browser tools
- every agent client needs bespoke Atlas integration before it benefits
- identity and isolation cannot be derived from enforceable host boundaries
- the browser and preview experience is not materially easier than existing tools
- owning the OS does not produce enough reliability or recovery benefit to justify an image

## Strategic test

Atlas is worth continuing if people with dedicated or underused compute choose to turn it into an Atlas instead of manually administering another Linux server, while continuing to use the agent interfaces they already prefer.

The short promise is:

> Turn a computer nobody will sit in front of into a complete, observable computer for agents.
