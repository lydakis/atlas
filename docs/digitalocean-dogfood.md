# DigitalOcean dogfood laboratory

Status: live dogfood proof complete, August 29, 2026

This laboratory exists to exercise Atlas through Herdr and ordinary SSH while
physical x86 hardware is unavailable. It is a persistent, remotely reachable
development host. It does not redefine Atlas as a cloud VM product and does not
prove the physical installer, hardware compatibility, owner-controlled disk
unlock, or local recovery.

## Shape

```text
DigitalOcean Droplet root disk
├── NixOS host and Atlas control plane
├── recovery and update headroom
└── temporary bootstrap OpenSSH, then Tailscale only

DigitalOcean Block Storage volume: atlas-data
└── Btrfs mounted at /var/lib/atlas
    ├── resettable environment roots and snapshots
    ├── durable /home/owner
    └── durable /home/owner/Projects
```

The volume is elastic only within its provisioned provider capacity. It has no
Atlas per-environment quota and can be enlarged later. Keeping it separate from
the root disk provides structural host recovery headroom. DigitalOcean manages
the volume's at-rest encryption; Atlas has no owner-held unlock key and the
provider remains inside the storage trust boundary.

The profile resolves the provider's stable device path
`/dev/disk/by-id/scsi-0DO_Volume_atlas-data`. It never formats that device.
Atlas accepts an explicitly prepared Btrfs volume and fails closed on a blank
device or any other filesystem.

## Deployment outputs

```bash
# Image with temporary key-only root SSH for first enrollment.
nix build .#packages.x86_64-linux.digitalocean-image

# Profiles used to update a running host.
nixos-rebuild switch --flake path:.#atlas-digitalocean-bootstrap-x86_64
nixos-rebuild switch --flake path:.#atlas-digitalocean-x86_64
```

The bootstrap profile permits only root public-key authentication on TCP 22.
Password and keyboard-interactive authentication are disabled, and environment
login accounts are excluded from OpenSSH. Restrict port 22 to the operator's
current public IP with a DigitalOcean Cloud Firewall before creating the
Droplet. This listener is a temporary recovery compromise, not an Atlas access
primitive.

Create a new unformatted volume named `atlas-data`, attach it to the Droplet,
and resolve the exact provider device before the only destructive setup step:

```bash
device=/dev/disk/by-id/scsi-0DO_Volume_atlas-data
test -b "$device"
lsblk --fs "$device"
wipefs --no-act "$device"
mkfs.btrfs --label atlas-data "$device"
```

Run `mkfs.btrfs` only after confirming this is the newly created empty volume.
It permanently destroys anything already stored on the target. The Atlas
module deliberately does not automate or repeat this step.

After formatting, reboot once. The image retries the named volume, mounts it,
and brings Atlas up. The image embeds the exact source that built it at
`/etc/atlas/image-source`, so the bootstrap-to-steady transition does not depend
on an unpublished Git commit.

Once Atlas is ready:

```bash
atlas doctor --json
atlas environment list --json
atlas-enroll
```

Switch to the embedded steady profile:

```bash
embedded_source="$(readlink -f /etc/atlas/image-source)"
case "$embedded_source" in
  /nix/store/*-source) ;;
  *) printf 'unexpected embedded source: %s\n' "$embedded_source" >&2; exit 1 ;;
esac
nixos-rebuild switch \
  --flake "path:$embedded_source#atlas-digitalocean-x86_64"
```

The steady profile disables OpenSSH and metadata-managed root SSH keys. Verify
from the provider console that TCP 22 is closed, verify Tailscale SSH from the
controller, then remove the bootstrap Cloud Firewall rule. Do not remove the
rule until private access and provider-console recovery have both been checked.

```bash
test ! -e /root/.ssh/authorized_keys
ss -ltn | grep -Eq '(^|[[:space:]])[^[:space:]]*:22[[:space:]]' && exit 1 || true
```

For later updates, clone a reviewed public Atlas revision into a root-owned
directory under `/var/lib/atlas/control` and switch using its flake. Do not make
the durable owner workspace the host's update authority.

## Herdr and two-environment ceremony

Install Herdr independently inside each environment that should run a Herdr
server. This is ordinary resettable environment drift, not an Atlas host
component:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
curl -fsSL https://herdr.dev/install.sh | sh
herdr --version
```

From the controller Mac, replace `<tailnet-host>` with the node's MagicDNS name.
The environment logins remain ordinary SSH targets:

```bash
ssh atlas-shared-dev@<tailnet-host>
ssh atlas-personal-dev@<tailnet-host>
herdr --remote atlas-shared-dev@<tailnet-host>
herdr --remote atlas-personal-dev@<tailnet-host>
```

If Herdr's managed SSH multiplexing is unreliable, configure Herdr locally with
`remote.manage_ssh_config = false` so it uses the already working plain SSH
path. Atlas does not configure Herdr or adopt its task model.

In `shared-dev`, verify the environment and create the durable checkout:

```bash
id
pwd
git config --get user.name
git config --get user.email
printf '%s\n' "$DEMO_GENERATION" "$DEMO_OVERRIDE"
git clone https://github.com/lydakis/atlas.git ~/Projects/atlas
printf 'shared environment\n' > ~/.config/atlas-dogfood
printf 'durable owner work\n' > ~/Projects/atlas/.atlas-dogfood-untracked
sudo apt-get update
sudo apt-get install -y ripgrep
```

In `personal-dev`, verify its different Git identity and the same durable data:

```bash
git config --get user.name
git config --get user.email
test -f ~/Projects/atlas/.atlas-dogfood-untracked
test ! -e ~/.config/atlas-dogfood
```

The Git identities are non-secret commit configuration. This proof does not put
a GitHub token, SSH private key, or credential helper inside either environment.
Atlas Grants do not exist yet, so authenticated pushes are deliberately outside
this ceremony.

From the host-administrator login, snapshot and reset `shared-dev`:

```bash
sudo atlas environment snapshot create shared-dev before-reset --json
sudo atlas environment reset shared-dev --json
```

Re-enter `shared-dev` and verify the boundary:

```bash
test ! -e ~/.config/atlas-dogfood
test ! -x /usr/bin/rg
test -f ~/Projects/atlas/.atlas-dogfood-untracked
git -C ~/Projects/atlas status --short
```

Reset intentionally does not discard repository changes because repositories
are durable owner data. Use ordinary Git restore, a disposable worktree, or a
fresh checkout when the test specifically wants to discard code changes.

Finally reboot the Droplet and repeat the identity, checkout, and Tailscale SSH
checks. Record failures and timing in `docs/nixos-spike.md` only after the live
run has actually happened.

## Laboratory size

The live run uses one 2-vCPU, 4-GiB Droplet plus one 50-GiB Block Storage
volume. Backups are off initially. The operator should create replacement paid
resources only after reviewing current provider pricing and the exact region,
image, SSH key, firewall, and deletion plan.
