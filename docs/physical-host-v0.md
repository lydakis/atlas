# Physical host v0

Status: live-image dogfood path, August 2026

Atlas targets a physical computer dedicated primarily to agents. The current
artifact is deliberately smaller than that product: it is a non-persistent live
image that can validate boot, interactive Tailscale enrollment, private SSH,
host policy, and two isolated demonstration environments on representative
hardware.

It does not install Atlas to disk or preserve state across a power cycle.

## Build the image

On a machine with Nix:

```bash
nix build .#packages.x86_64-linux.physical-iso
```

On a machine without Nix, use the pinned container helper when Docker is
available:

```bash
docker volume create atlas-nix-store
./scripts/nix-container build \
  path:/workspace#packages.x86_64-linux.physical-iso
```

The result symlink points at the generated ISO. Use a trusted graphical image
writer to write it to a USB drive. Selecting the wrong target drive can destroy
data, so Atlas does not currently wrap that operation in a convenience script.

The generic x86 image is the first physical target. ARM hardware often needs
board-specific firmware and boot configuration, so an AArch64 build evaluating
successfully is not a claim that it will boot on arbitrary ARM computers.

## Boot and enroll

The live image logs the local console into the password-disabled
`atlas-operator` account for first-boot dogfooding. That console session has
passwordless sudo and therefore host-root authority. The image does not enable
a login password or public SSH server.

At the console, run:

```bash
sudo atlas-enroll
```

The command runs interactive Tailscale enrollment, displays a QR code and login
URL, and requests Tailscale SSH. No Tailscale auth key is embedded in the image
or written to the Nix store.

After the host appears in the tailnet and the tailnet policy authorizes the
connection, connect from another enrolled device using its Tailscale name:

```bash
ssh atlas-operator@atlas-spike
```

`atlas-operator` has host-administrator authority in this spike. Tailnet policy
must therefore restrict that login to the operator and should require a fresh
identity check for sensitive access. Tailnet membership alone should not be
treated as permission to administer Atlas.

The connection is served by Tailscale SSH. The image does not enable OpenSSH or
open TCP port 22 on public or LAN interfaces.

## Inspect the current contract

```bash
cat /etc/atlas/host-contract.json | jq
systemctl status atlas-host.target
systemctl status atlas-spike-alpha
systemctl status atlas-spike-beta
```

The alpha and beta services demonstrate two environment process boundaries.
Each runs as a dynamic non-root user, has its own network namespace, sits in
`atlas-environments.slice`, and binds `127.0.0.1:3000` without colliding.

They are not interactive environments for Codex, Herdr, or T3 Code. That is
the next implementation boundary.

## What this dogfood run should record

- exact hardware model, firmware mode, CPU architecture, storage, and network
- whether the image boots without distribution-specific intervention
- whether Ethernet or Wi-Fi is available before enrollment
- time from power-on to tailnet reachability
- Tailscale connection type and SSH reliability across a client disconnect
- behavior after suspend, restart, network changes, and tailnet-policy revocation
- whether local-console recovery remains available after a remote-access error

Do not test with primary browser identities, personal password vaults, or
consequential credentials. The current image has no browser or grant boundary.

## Next persistent image

The next artifact must install to an explicitly selected disk and define:

- UEFI and representative hardware support
- encrypted persistent state under `/var/lib/atlas`
- the unattended-boot versus operator-unlock tradeoff
- a separate recovery path and key rotation
- authenticated system updates and bootloader rollback
- preservation of environments, browser profiles, grants, routes, and records
- a factory-reset operation that is explicit and recoverable where possible

Disk installation is intentionally not automated until those choices are made.
