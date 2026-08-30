# Atlas documentation

Atlas separates product commitments, implementation order, normative contracts,
security analysis, and experimental evidence. Read each document according to
its role rather than treating every design note as an implementation promise.

## Start here

- [Product thesis](product-thesis.md) explains why Atlas exists, what belongs in
  the machine layer, and which outcomes would invalidate the idea.
- [Roadmap](roadmap.md) is the sole authority for implementation order and
  current proof status.
- [Interop contract](interop-contract.md) defines the boundary between Atlas and
  existing agent clients.
- [Threat model](threat-model.md) records current authority boundaries, known
  degradations, and security claims that still require proof.

## Product contracts

- [Environment Entry v0](environment-entry-v0.md)
- [Persistent Storage v0](persistent-storage-v0.md)
- [Authenticated Surface v0](authenticated-surface-v0.md)
- [Physical Host v0](physical-host-v0.md)

These documents define intended behavior. A contract is not evidence that the
behavior has been implemented or validated.

## Evidence and explorations

- [NixOS architecture spike](nixos-spike.md) records what the current adapter
  has actually demonstrated and where it remains degraded.
- [DigitalOcean dogfood laboratory](digitalocean-dogfood.md) defines the
  replaceable remote test host and the exact existing-client ceremony. It is a
  runbook, not physical-product evidence.

Evidence claims belong in a test or spike report. Implementation status belongs
in the roadmap. This keeps the durable product thesis independent of whichever
host distribution or isolation backend Atlas is currently testing.
