# Contributing to Atlas

Atlas is an early product and architecture exploration. Contributions are most
useful when they make a host guarantee precise, testable, and independent of a
particular agent client.

## Before proposing an implementation

Read the [documentation map](docs/README.md), [product thesis](docs/product-thesis.md),
[interop contract](docs/interop-contract.md), and [threat model](docs/threat-model.md).
For significant changes, start with an issue that describes:

- the operator problem being solved
- the invariant Atlas should guarantee
- how the guarantee will be tested
- which parts belong to Atlas rather than an agent client or harness
- the security and recovery consequences

Keep implementation spikes narrow. Atlas has not selected a base distribution
or final workload-isolation backend.

## Validating the current spike

```bash
python3 -m unittest discover -s tests -v
nix flake check --all-systems --no-build
nix build .#checks.aarch64-linux.control-unit
nix build .#checks.aarch64-linux.host-contract
```

If Nix is not installed, use the pinned Docker helper documented in the
[README](README.md#try-the-architecture-spike).

Please keep changes focused, format Nix with `nix fmt`, and include tests for
new host contracts or behavior.

## Implementation map

The NixOS module declares the desired host and environment contract. The Python
package under `src/atlas` realizes the local control plane without becoming a
second source of product policy:

- `control.py` owns the Unix-socket protocol, peer-derived authorization, and
  command-line surfaces.
- `lifecycle.py` owns reset and snapshot orchestration.
- `storage.py` owns directory and Btrfs filesystem mechanics.

Keep the local protocol stable across internal refactors. Add a new abstraction
only when a second implementation or a security boundary makes the seam real.

## Security reports

Do not open a public issue for a vulnerability that could put users or systems
at risk. Use GitHub's private vulnerability reporting for this repository when
available.
