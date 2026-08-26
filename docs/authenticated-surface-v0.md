# Authenticated Surface v0

Status: proposed product contract, August 2026

## Outcome

Authenticated Surface v0 is the first security milestone inside Atlas's first
end-to-end product proof. The broader proof also covers physical installation,
environment entry, private routing, capability reporting, reboot, and update as
defined in the product thesis.

An existing agent client running inside one Atlas environment can operate a
persistent browser identity. When authentication is required, Atlas fences that
environment's surface capability, lets the operator take exclusive control from
a paired device, and then returns control without exposing the browser profile
to the environment. The agent may continue unrelated work, but it cannot act on
or observe that surface during the handoff. A second environment cannot acquire
the same authority.

This milestone proves a machine-level trust boundary beneath Codex, Herdr, T3
Code, Blue, SSH, and other clients. It does not introduce an Atlas agent, chat,
task, repository, or password manager.

## Acceptance story

1. The operator installs Atlas on a representative physical machine, enrolls
   it into a private network, and creates Environment A.
2. An existing agent client enters Environment A through its ordinary remote
   workflow.
3. Environment A requests a new browser identity with a low-risk test account.
4. The surface reference monitor creates a per-identity browser worker whose
   process, profile, automation endpoint, display, clipboard, downloads, and
   recordings remain outside the environment filesystem and process boundary.
5. Environment A or the operator explicitly requests authentication. Atlas does
   not infer that page content is a sign-in form or let a page create an
   authentication request.
6. The operator verifies broker-owned context with explicit provenance and
   takes exclusive control. Environment access, every non-controller observer,
   agent/model capture, recordings, clipboard observation, and surface-derived
   metadata stop before operator input is enabled.
7. The operator authenticates using a password, passkey, or second factor. A
   password necessarily traverses the protected operator-input path and exists
   transiently in the browser and remote service. Subject to the password-path
   requirements below, it does not enter agent context, environment storage,
   Atlas audit events, recordings, browser password storage, or the Nix store.
8. Atlas returns bounded browser control to Environment A. The authenticated
   profile persists according to its declared policy.
9. The operator can observe, take over, revoke access, sign out, or destroy the
   browser identity independently of the agent client.
10. Environment B cannot read the profile, attach to the browser, reuse the
    grant, observe the display, inspect recordings, or operate the identity.

The proof uses a disposable or low-risk account. Atlas does not ask for a
primary email, financial, administrative, healthcare, or production identity
until the boundary has passed adversarial testing.

## Product decisions

### Atlas stores sessions, not a password vault

The operator's password manager remains on the operator device. Atlas does not
sync a personal password vault or general browser profile to the host.

Atlas may persist:

- an authenticated browser profile, including cookies and site storage but not
  the operator's source password
- grant and controller state
- pairing, encryption, and broker keys required by the control plane
- redacted security events

These are all sensitive. An authenticated browser session is reusable account
authority even when Atlas never stores the original password.

For v0, password saving, profile sync, and browser or OS credential-store writes
of operator source passwords are disabled by enforced browser policy. A saved
source password is a failed milestone, not a degraded capability.

Atlas may later accept credentials from optional provider adapters. No provider,
including Apple Passwords, 1Password, Bitwarden, or a hosted vault, defines the
v0 contract.

### The environment is the security principal

A grant binds to an Atlas environment identity observed by the host. A client
may add task, conversation, agent, or process labels for attribution, but those
labels cannot establish authority.

V0 grants authority to the observed environment. Atlas does not claim
process-scoped isolation until it can bind a lease to a pidfd or equivalent
process identity, cgroup membership, boot and process generation, child and
file-descriptor delegation rules, death and restart behavior, and per-operation
revalidation. A future process lease must still remain bound to the owning
environment.

Until that boundary exists, sibling processes inside one environment belong to
the same browser trust context. An operator who needs two agent instances to
hold different browser authority creates separate environments.

A browser identity is not reassigned between environments. Profile persistence
and grant lifetime are independent: an identity may remain locked after a grant
expires, but another environment does not inherit it. Sharing the same website
account across trust contexts requires separately authenticated profiles.

### Browser control is an explicit capability

Authenticated Surface v0 exposes bounded observation and action operations. It
does not expose unrestricted Chrome DevTools Protocol, WebDriver, a browser
debugging port, the profile directory, or a shell in the browser service.

Atlas may add a declared debug capability later. Because common browser-debug
protocols can export cookies and site storage, that capability must be reported
as equivalent to receiving reusable browser credentials.

### Authentication does not pre-authorize consequential action

Signing in authorizes use of an account. It does not pre-approve purchases,
messages, account changes, destructive operations, publication, or other
consequential actions.

Authenticated Surface v0 does not provide a semantic consequential-action gate.
A cooperative client or operator may interrupt control before an action, but a
host cannot enforce a confirmation that a hostile client can simply decline to
request. A future gate must bind a single approval to an exact action, origin,
document, navigation, browser identity, controller epoch, expiry, and single-use
request identifier.

## Internal trust partition

The surface subsystem has two security roles rather than one shared trusted
browser service.

1. **Surface reference monitor:** a small host-control process that authenticates
   callers, evaluates grants and controller epochs, coordinates takeover,
   redacts events, and creates or destroys workers. It does not render untrusted
   pages. It treats every worker- or page-derived value as untrusted input,
   validates it before use, and reports whether a displayed fact was
   independently enforced, independently observed, worker-reported, or
   unavailable.
2. **Per-identity browser worker:** one browser identity and its renderers,
   profile, runtime tree, display, and mediated network context. Web content and
   the entire worker are treated as hostile to the host control plane.

Each worker has a separate OS identity, mount and runtime tree, cgroup, IPC
boundary, and network context. It cannot read another profile, broker state,
host control sockets, environment files, or another worker's processes. A
browser compromise should yield only that worker's profile, account authority,
and data, not another identity or Atlas host authority. A reusable password
entered into a compromised worker can still be captured by that worker because
the renderer necessarily receives it. V0 does not claim otherwise and therefore
uses only a disposable or low-risk account for this proof.

This is a product requirement, not a claim about the current spike. The spike
only creates placeholder state roots and demonstration process boundaries.

## Ownership and trust boundaries

| Resource | Owner | Environment access | Persistence |
| --- | --- | --- | --- |
| Source password vault | operator device | never | outside Atlas |
| Transient password input | operator and bounded input path | never available to an environment | never retained |
| Passkey private key | operator device or security key | never | outside Atlas |
| Surface reference monitor | Atlas control plane | authenticated requests only | runtime |
| Browser worker | separate identity per browser identity | bounded action interface through reference monitor | runtime |
| Browser profile and cookies | per-identity worker store | no environment filesystem or debug access | declared per identity |
| Display and input channel | per-identity worker through reference monitor | observe or control according to controller state | runtime |
| Grant metadata | Atlas control plane | inspect own effective grant | policy-defined |
| Screenshots and recordings | per-identity worker store through reference monitor | explicit read grant only | declared retention |
| Audit events | Atlas control plane | no write access | declared retention |

Each browser worker runs under a dedicated, minimally privileged host identity.
It does not run as the environment user, the reference monitor, or host root.
Endpoint references may be copied, so possession of a path, port, handle, or
logical identifier is never authorization. The reference monitor reauthenticates
peer credentials, current environment membership, grant state, and controller
epoch on every operation.

## Paired operator minimum contract

The paired-device mechanism is an implementation choice, but v0 requires these
observable behaviors:

- each device has a distinct host-bound identity enrolled through an existing
  trusted operator or a local recovery ceremony
- takeover and secret entry require fresh operator verification, not merely an
  unlocked device or possession of a URL
- device-to-host observation and input are end-to-end encrypted; an optional
  rendezvous or relay cannot decrypt browser pixels, input, or credentials
- the operator can list and revoke a lost device, invalidating its outstanding
  requests and terminating its active observation and control sessions
- replacing the last device requires a local recovery path and cannot silently
  transfer browser identities or profile keys
- takeover does not begin until every other observer has acknowledged the new
  controller epoch and disconnected from the surface data path

Private-network membership supplies reachability, not paired-device or operator
authority.

## Minimal external interface

The interface is behavioral. The daemon transport, CLI shape, operator web UI,
and client adapters remain implementation choices.

### Request a browser identity

The request supplies:

- identity disposition: create, or reuse an identity already bound to the
  requesting environment
- persistence policy: ephemeral or persistent
- trust label and human-readable purpose
- requested origin set
- requested operations and duration
- reason for the request

Atlas derives the requesting environment from the authenticated entry boundary.
It does not accept an environment identifier as proof of authority.

### Operate a surface

The v0 action capability is intentionally smaller than a browser-debug protocol:

- navigate within an approved origin policy
- capture a current view when capture is permitted
- point, click, scroll, and type agent-supplied text
- inspect current URL, title, loading state, and controller state while the
  environment is the active controller
- request operator authentication or takeover
- release control

The exact action vocabulary should be chosen with the first client adapter. It
must not leak DOM storage, cookies, authorization headers, password values, or
arbitrary browser-process execution through a convenience method.

### Observe state

An authorized caller can determine:

- effective environment and browser identity
- current origin and requested origin policy
- current controller and whether capture is suspended
- persistence, recording, retention, and automation capability
- grant issue time, expiry, status, and revocation state
- degraded guarantees, including any debug-capable adapter

While takeover is pending or operator control is active, an environment can
observe only a redacted controller status. URL query and fragment data, title,
loading and navigation state, browser pixels, accessibility data, clipboard,
downloads, and recordings are unavailable until explicit return creates a new
controller epoch.

### Revoke authority

Atlas distinguishes five operator actions:

1. **Lock control:** advance the controller epoch, reject new environment work,
   and fence or complete already accepted Atlas operations before reporting the
   surface locked.
2. **Quarantine execution:** freeze or stop the worker and cancel locally
   cancellable browser work. This is stronger than locking control but still
   cannot undo an action already committed to a downstream service.
3. **Request downstream logout or revocation:** use a site-supported operation
   and report whether the downstream service confirmed it.
4. **Clear local session:** remove selected local site data and require local
   authentication again. This does not prove server-side invalidation.
5. **Destroy local identity:** stop the worker, revoke its grants, destroy its
   profile key, and make local profile, recording, and derived state
   inaccessible according to deletion policy. Filesystem deletion alone is not
   reported as secure erasure on copy-on-write filesystems or SSDs.

Revocation must not depend on cooperation from the agent client. Locking or
revoking Atlas authority does not claim that page scripts or network requests
inside a still-running worker have stopped; Atlas reports execution quarantine
as a separate outcome.

Environment identities are opaque and non-reusable. Deleting an environment in
v0 requires explicit confirmation and destroys its browser workers, grants, and
profile keys. Recreating the same human-readable environment name inherits
nothing.

## Controller state machine

At most one party has interactive control.

```text
          authentication or takeover requested
agent control -------------------------------> pending operator
      ^                                               |
      |                                               v
      +---------------------------------------- operator control
              fresh authenticated return

pending/operator -- context change or failure --> locked
any state -- lock or revoke ------------------> locked
locked -- fresh operator restore + valid grant -> agent control
any state -- destroy -> removed
```

Entering `pending operator` requires a quiescence barrier. The reference
monitor advances the controller epoch, rejects new environment requests,
cancels or completes already accepted actions, and waits for acknowledgement
from the action, observation, clipboard, download, and recording pipelines. If
any pipeline cannot fence the old epoch, the surface fails locked and takeover
does not begin.

The barrier fences Atlas automation. It does not claim that scripts or network
requests already running inside the web page have stopped. The operator sees
that limitation and may reload, stop, or destroy the worker before entering a
secret.

While `pending operator` or `operator control` is active:

- agent input is rejected rather than queued
- every other observer session is fenced and disconnected before operator input
  is enabled
- agent/model screenshots and persistent recordings are suspended
- browser image, accessibility, URL, title, loading, and navigation data are not
  sent to an environment, agent, or model
- clipboard synchronization and download access are disabled
- the operator UI visibly identifies the Atlas host, environment, browser
  identity, controller state, and the provenance of every destination fact

The operator input path remains bound to the request's surface, document,
navigation, top-level origin, focused-frame origin, and controller epoch. Any
change advances the epoch, disables operator input, invalidates the request, and
leaves the surface locked. Input can resume only after a fresh authenticated
transition. The implementation must order context events and input at the
reference monitor; if it cannot prove which epoch accepted an input operation,
it fails locked.

Returning control creates a new controller epoch. Input or observation requests
from an earlier epoch fail closed. Denial, grant expiry, restart,
reference-monitor failure, or loss of the operator connection leaves the
surface locked. Leaving `locked` requires a fresh authenticated operator action
and a currently valid environment grant.

Lock and revocation use the same quiescence barrier as takeover. They reject new
work, cancel or complete accepted Atlas operations, and wait for every pipeline
to acknowledge the new epoch before reporting success.

## Authentication handoff

An authentication request contains broker-owned context with explicit
provenance, not agent-authored UI.

Reference-monitor-observed facts are:

- Atlas host and environment identity
- browser identity, surface identity, and declared purpose
- effective grant, controller epoch, expiration, and single-use request
  identifier
- capture, recording, observer, and input-fencing state

Browser-worker-reported facts are:

- browser document and navigation identity
- current URL, top-level origin, focused-frame origin, and TLS state available
  to the browser
- requested origin-policy additions, including identity-provider redirects

Worker-reported facts appear in broker-owned chrome but remain visibly labeled
as worker-reported. A destination restriction may be labeled independently
enforced only when a policy point outside the hostile worker enforces it for all
relevant requests. Unavailable provenance is shown as unavailable, never
silently promoted to a host fact.

The operator opens the request through an authenticated, paired-device channel.
A takeover URL alone is not authority. It is short-lived, single-use, bound to
the host, environment, identity, surface, document, navigation, request, and
controller epoch. Browser-derived facts appear in broker-owned chrome, not
page-controlled content, with the provenance above. The request is
invalidated on completion, denial, navigation, focused-frame origin change,
expiry, or controller change. During operator control the same changes
immediately fence input and transition the surface to `locked`.

V0 supports two authentication paths:

1. **Remote takeover:** the operator types or pastes into the real remote
   browser through a dedicated operator-input path while agent/model capture is
   suspended. Secret input is never represented in an environment command or
   Atlas audit payload.
2. **Cross-device passkey:** the remote browser displays the site's passkey QR
   flow and the operator completes it with a nearby phone or security key. The
   passkey private key remains on that device.

Apple Passwords AutoFill is not a v0 dependency. A remote browser is not
necessarily an AutoFill-capable local field for the target origin, so Atlas
must not promise that Apple Passwords can fill it automatically. A native
operator companion or provider adapter is a later interoperability question.

The operator explicitly returns control after confirming the intended account
and post-login state. Atlas does not claim it can identify the correct account
semantically on every website.

### Password path and capture boundary

A password can be hidden from an agent without remaining entirely on the
operator device. For remote takeover it may pass through the paired-device
input code, encrypted transport, host input service, browser renderer, and
remote website. Before claiming source-credential protection, an implementation
documents each plaintext recipient and proves that no relay, log, crash report,
core dump, unencrypted swap path, browser password store, accessibility export,
or persistent clipboard history retains it.

The retention boundary is structural. While password entry is enabled:

- browser password saving, profile sync, form-value restoration, and OS
  credential-store writes of the source password are disabled by policy
- crash reporting, core dumps, input logging, telemetry payloads, and
  accessibility exports cannot retain operator input
- swap is disabled or encrypted under the declared profile-protection boundary
- the browser profile, worker logs, journals, and crash-artifact locations form
  an enumerated inspection set for the required proof

A negative search without that policy and artifact inventory is not accepted as
proof.

The operator's encrypted live stream still carries browser pixels and input.
"Capture suspended" means that agent/model observation and persistent recording
are fenced. It does not mean the operator stream has disappeared. Any relay and
its end-to-end encryption, metadata, retention, and compromise model must be
reported.

Direct entry through the dedicated input path is preferred. Pasting additionally
exposes the password to the operator device's system clipboard and any enabled
clipboard-sync service; those become declared plaintext recipients. Atlas sends
only the selected input and does not synchronize or retain the operator
device's general clipboard.

## Origin and action policy

An origin policy is an allowlist of browser destinations, not proof that page
content is trustworthy. Authentication redirects often require several origins,
so a grant may declare an expected identity-provider set before the live flow.
Atlas prompts only for an addition outside that declared set and never silently
expands authority from one site to an identity provider.

The policy declares its enforcement coverage. V0 mediates agent-requested
top-level navigations, redirects, and popups through the bounded adapter, but
that alone does not constrain navigation initiated by a hostile worker. Atlas
calls a public-web origin restriction independently enforced only when a policy
point outside the worker covers every relevant request and redirect. Otherwise
it reports the policy as adapter-scoped guidance and subresource traffic as
unrestricted rather than implying an egress or data-loss-prevention boundary.
Downloads and external application launches require separate policy. The
implementation fails visibly when it cannot enforce a declared restriction.

Independently of public-web origin policy, a browser worker is denied Atlas
control sockets, other worker endpoints, host loopback, private LAN and tailnet
addresses, and cloud metadata endpoints by default. Browser `localhost` refers
to the worker's own network context, not the Atlas host. Access to a private
service is a separate environment-bound grant with an explicit destination.
This private-destination denial is enforced outside the worker for every
request, including subresources, redirects, popups, raw sockets, and DNS answers
that resolve or rebind into a denied range.

The reference monitor's browser-automation endpoint is not a TCP listener in the
worker network context. It uses a protected Unix socket, inherited descriptor,
or equivalent channel that hostile renderer processes cannot attach to.

Uploads, downloads, and external-application launches cross another data
boundary and are mediated separately. An internet-enabled worker may transmit
data available to its authenticated page through allowed requests, so Atlas
does not describe top-level origin mediation as data-loss prevention.

An authorized environment can still misuse every website action available to
the signed-in account. Atlas v0 does not claim semantic least privilege inside
a website. Narrow accounts, restricted origin policy, short grant lifetimes,
and voluntary operator interrupts reduce risk but do not eliminate prompt
injection or malicious-agent behavior.

## Persistence and encryption

Persistent browser state is stored beneath the Atlas mutable-state boundary in
a per-identity worker store controlled by the reference monitor, not an
environment. It must be encrypted at rest before the milestone uses a real
account.

Atlas reports the effective unlock mode, such as operator unlock, hardware-
sealed automatic unlock, or unprotected. Encryption protects a powered-off or
stolen disk; it does not protect data from compromised host root while the
profile is unlocked.

Reboot durability is conditional on that reported unlock mode. With automatic
unlock, Atlas proves the declared persistent profile becomes available after
reboot. With operator unlock, the encrypted bytes remain durable but the
surface stays locked and unavailable until an authenticated operator unlocks
it. An unprotected profile cannot satisfy Authenticated Surface v0.

Small control-plane keys may use host credential facilities such as TPM-backed
systemd credentials. Browser profiles require an encrypted storage design and
cannot be modeled as immutable service-start credentials.

Backups are disabled for authenticated profiles in v0 unless the backup format,
key custody, retention, restore behavior, and remote revocation semantics are
explicitly implemented and tested.

## Security events

Atlas records metadata for:

- identity creation, start, stop, lock, and destruction
- grant request, approval, denial, expiry, renewal, and revocation
- origin-policy change
- controller and controller-epoch transition
- capture or recording transition
- authentication requested, completed, failed, or abandoned
- blocked cross-environment or stale-controller attempt

Events never contain passwords, one-time codes, cookie values, authorization
headers, typed secret input, full page content, or screenshots by default.

## Required proof

Authenticated Surface v0 is complete only when automated tests or reproducible
operator checks prove all of the following:

### Positive path

- an existing agent client in Environment A can request and operate the surface
- operator takeover works from a paired device and is visibly exclusive
- capture stops before secret input and resumes only after explicit return
- a low-risk account remains authenticated across browser restart; after host
  reboot it either becomes available under declared automatic unlock or remains
  visibly locked pending declared operator unlock
- the operator can revoke control without the agent client's cooperation
- a lost paired device can be revoked and its active sessions and outstanding
  requests stop working

### Isolation and extraction resistance

- Environment A cannot read the profile directory or browser credential files
- Environment A cannot attach a debugger, inspect browser process memory, or
  reach an unbrokered browser automation endpoint
- copied endpoint identifiers and stale file descriptors do not bypass
  per-operation caller, grant, and controller-epoch checks
- Environment B cannot read, observe, control, or reuse any identity, grant,
  surface, recording, or takeover request bound to Environment A
- every non-controller observer is fenced before operator input is enabled
- a compromised browser worker cannot read another profile or worker, connect
  to the reference monitor as an environment, or access host control sockets,
  host loopback, private-network services, or cloud metadata without a grant
- a compromised renderer cannot attach to an unbrokered browser-automation
  endpoint
- source credentials do not appear in environment files, process arguments,
  process environments, agent/model capture, logs, events, recordings, browser
  password storage, crash artifacts, build outputs, or the Nix store
- every plaintext password recipient and operator-stream relay is documented,
  minimized, and covered by the declared capture and retention policy
- takeover begins only after every Atlas-controlled input, observation,
  clipboard, download, and recording pipeline acknowledges the new controller
  epoch
- navigation, document change, or focused-frame origin change during operator
  control fences input and requires a fresh authenticated transition
- a stale takeover request and stale controller epoch fail closed
- lock and revocation fence accepted Atlas operations, not only new attachment
  attempts, and execution quarantine is reported separately
- deleting an environment destroys its bound profile keys, and recreating its
  name inherits no browser identity or grant
- local deletion, profile-key destruction, and confirmed downstream revocation
  are tested and reported as different outcomes

### Honest capability reporting

- Atlas reports whether state is encrypted and how it unlocks
- Atlas reports profile persistence and recording retention
- Atlas reports the provenance of destination facts and whether an origin or
  private-destination restriction is independently enforced
- Atlas reports any adapter that can export cookies as debug-capable authority
- Atlas reports unavailable origin, action, capture, or revocation guarantees
  as degraded or unsupported rather than silently continuing

## Implementation order

1. Implement and test the persistent physical-host boundary with encrypted
   Atlas state, declared unlock behavior, private enrollment, update, and
   recovery.
2. Select and prove one interactive environment backend with a kernel-observed
   identity and protected local capability endpoint.
3. Build the surface reference monitor with controller epochs, the complete
   state machine, provenance-aware destination reporting, origin and private-
   destination policy, and redacted security events.
4. Add one per-identity Chromium worker with a protected network and automation
   channel, password-retention policy, and one bounded action adapter.
5. Build the paired-device flow with end-to-end-protected observation and input,
   exclusive takeover, return, device revocation, and recovery.
6. Add encrypted persistent profile policy under the declared unlock mode.
7. Run the proof with one low-risk account and two hostile test environments.
8. Only after this boundary passes, design a separate brokered-credential
   milestone for Git, SSH, cloud, or API authority.

## Deferred decisions

- persistent installer and encrypted-storage mechanism
- environment isolation backend
- browser rendering, streaming, and action transport
- browser-worker isolation and network-policy mechanism
- first agent-client adapter
- paired-device identity, operator-authentication, end-to-end transport, relay,
  revocation, and recovery implementation mechanisms that satisfy the minimum
  contract above
- process-lease proof, inheritance, delegation, restart, and expiry semantics
- controller restart, monotonic-time, and clock-rollback behavior
- policy for federated login redirects and browser subresources
- definition, detection, and context-bound approval of consequential actions
- mediated upload, download, and external-application behavior
- hardware-sealed unattended unlock versus operator-assisted unlock
- native Apple-platform companion and third-party credential-provider adapters
- multi-operator and shared-identity policy

These decisions must preserve this contract. They should not be selected only
because a particular OS base, browser framework, or agent client makes one
implementation convenient.

## Research inputs

- [OpenAI cloud-browser sign-in and takeover](https://help.openai.com/en/articles/20001280-using-cloud-browser-in-chatgpt)
- [Apple Passwords platforms and AutoFill](https://support.apple.com/en-gb/120758)
- [Apple cross-device passkeys](https://support.apple.com/en-ie/guide/iphone/iphf538ea8d0/ios)
- [systemd system and service credentials](https://systemd.io/CREDENTIALS/)
- [Chrome DevTools Protocol storage capabilities](https://chromedevtools.github.io/devtools-protocol/tot/Storage/)
