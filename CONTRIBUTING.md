# Contributing to Atlas

Atlas is an early product and architecture exploration. Contributions are most
useful when they make a host guarantee precise, testable, and independent of a
particular agent client.

## Before proposing an implementation

Read the [product thesis](docs/product-thesis.md), [interop contract](docs/interop-contract.md),
and [threat model](docs/threat-model.md). For significant changes, start with
an issue that describes:

- the operator problem being solved
- the invariant Atlas should guarantee
- how the guarantee will be tested
- which parts belong to Atlas rather than an agent client or harness
- the security and recovery consequences

Keep implementation spikes narrow. Atlas has not selected a base distribution
or final workload-isolation backend.

## Validating the current spike

```bash
nix flake check --all-systems --no-build
nix build .#checks.aarch64-linux.host-contract
```

If Nix is not installed, use the pinned Docker helper documented in the
[README](README.md#try-the-architecture-spike).

Please keep changes focused, format Nix with `nix fmt`, and include tests for
new host contracts or behavior.

## Security reports

Do not open a public issue for a vulnerability that could put users or systems
at risk. Use GitHub's private vulnerability reporting for this repository when
available.
