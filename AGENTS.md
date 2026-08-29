# AGENTS.md

George Lydakis owns Atlas. Keep work concise, evidence-backed, and aligned with
the product boundary below.

## Product vision

Atlas is a managed operating environment for a physical computer whose primary
users are software agents. It is the machine layer beneath Codex, Herdr, T3
Code, Blue, SSH, and other agent clients. Those clients own prompts, tasks,
conversations, repositories, worktrees, terminals, and agent orchestration.
Atlas owns the host guarantees they should not each have to reinvent:
isolation, persistence, scoped authority, private reachability, observation,
updates, reset, and recovery.

The normal product shape is one human-owned box with one default environment
used by many agent processes and human clients. Additional environments are
optional boundaries for different credentials, network policy, conflicting
toolchains, reset policy, or resource limits. An agent is a program, not a user
identity and not the owner of an environment.

An Atlas environment should feel like ordinary mutable Linux. Its resettable OS
state persists until explicit reset and can grow elastically across the Atlas
data disk. Durable owner data is composed into that ordinary filesystem and
survives reset. Volatile process and connection state does not survive reboot.

Atlas currently has six product primitives: Host, Environment, Volume, Grant,
Surface, and Route. Do not add project, task, session, conversation, repository,
or agent-identity primitives without revisiting the product thesis.

## Product boundaries

- Existing agent clients remain the primary way people and agents use the box.
- A portable environment declaration is non-secret, declarative, explicitly
  applied, and never ambiently executes repository code.
- Secrets and authenticated browser identities are Grants, not environment
  configuration. Prefer brokered or capability-style access over materializing
  reusable credentials inside an environment.
- Tailnet membership provides private transport, not Atlas authorization.
  Controller devices require explicit, revocable pairing.
- The managed physical image is the product target. VMs are development,
  automated-test, and optional deployment artifacts.
- NixOS and systemd-nspawn are prototype vehicles, not permanent product
  decisions. Judge them by measurable behavior rather than implementation
  elegance.
- Report degraded guarantees honestly. Do not infer a security property from a
  configured mechanism without runtime evidence.

## Document authority

- `docs/product-thesis.md` defines the durable why, product boundary, and kill
  tests.
- `docs/roadmap.md` is the sole authority for implementation order and status.
- The v0 contract documents define intended behavior, not proof that it exists.
- `docs/threat-model.md` defines security boundaries and known degradations.
- `docs/nixos-spike.md` and tests record implementation evidence.
- `docs/README.md` maps the complete documentation set.

Keep these roles distinct. Update the roadmap when sequencing changes, a
contract when intended behavior changes, and evidence documents only when a
claim has actually been demonstrated.

## Current direction

The next product proof is a physical alpha on one selected x86 machine:
persistent installation, encrypted Atlas state with a declared unlock mode,
protected host recovery capacity, private enrollment, automatic durable owner
storage, and reboot/reset survival. Private environment networking, paired
operator control, and a private route form the next critical path; storage
hardening proceeds in parallel after the physical layout is proven. Do not
claim the browser, grant, portable-declaration, or host-base proofs ahead of
their roadmap prerequisites unless George explicitly changes the sequence.

## Implementation boundaries

- `nixos/modules/atlas-environments.nix` declares the current host and
  environment contract.
- `src/atlas/control.py` owns the local Unix-socket protocol, peer-derived
  authorization, and CLI surfaces.
- `src/atlas/lifecycle.py` owns reset and snapshot orchestration.
- `src/atlas/storage.py` owns directory and Btrfs filesystem mechanics.
- `tests/test_atlas_control.py` covers protocol and lifecycle regressions.
- `nixos/tests/host-contract.nix` is the end-to-end host proof.

Preserve the versioned local protocol across internal refactors. Keep one deep
lifecycle interface between control and mechanism code. Do not introduce a
remote transport abstraction until a real second transport exists.

## Engineering rules

- Prefer small, reviewable changes and preserve unrelated local edits.
- Work test-first for behavior changes and security fixes when practical.
- Keep credentials out of source, Nix store paths, logs, tests, and portable
  declarations.
- Do not weaken kernel-derived identity, root-only lifecycle authority, managed
  path validation, lifecycle locking, or fail-closed behavior.
- Use `rg` for search and `apply_patch` for manual edits.
- Do not commit or push unless George explicitly asks.

Before handoff, run the relevant subset of:

```bash
python3 -m unittest discover -s tests -v
nix flake check --all-systems --no-build
nix build .#checks.aarch64-linux.control-unit
nix build .#checks.aarch64-linux.module-evaluation
nix build .#checks.aarch64-linux.host-contract
nix build .#checks.x86_64-linux.installed-host
nix fmt -- --check
```

Without native Nix, use the corresponding `./scripts/nix-container` commands
documented in the root README.
