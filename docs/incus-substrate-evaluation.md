# Incus substrate evaluation

Status: selected Environment substrate; adapter integration and physical-image
qualification remain incomplete

Date: August 31, 2026

## Decision

Select Incus 7.0 LTS, as patched by the pinned NixOS package set, as the default
Atlas Environment substrate. Implement it behind the existing Atlas lifecycle
boundary. Keep the current systemd-nspawn and Btrfs implementation only as a
temporary reference until the Incus-backed adapter passes the existing control,
reset, snapshot, update, and installed-host contracts.

This decision completes the substrate spike. The remaining work is adapter
implementation and product qualification, not another substrate selection
spike. It does not yet prove the managed physical image.

Incus is implementation infrastructure beneath the Atlas Environment and Volume
primitives. It is not an Atlas client, a competing product control plane, or a
reason to add project, task, session, repository, or agent-identity primitives.
If Incus is later removed, Atlas's product contract should remain intact and a
different deep adapter should be able to implement it.

Upstream confirms that Incus is released under the
[Apache License 2.0](https://github.com/lxc/incus) and documents both its local
[authorization model](https://linuxcontainers.org/incus/docs/main/authorization/)
and [container execution contract](https://linuxcontainers.org/incus/docs/main/instance-exec/).
Those are source facts. The Atlas suitability decision below is based on the
repository's own runtime proof.

## Ubuntu image decision

The existing Atlas image and the Incus proof image are both Ubuntu Noble 24.04
LTS. The existing adapter pins Canonical's `20260810` Noble OCI root filesystem;
the Incus proof pins the Linux Containers `20260829_07:42` Noble `default`
system image. The 19-day difference is incidental and did not cause the
compatibility problem.

Ubuntu 26.04 is now the newest LTS. Atlas is not switching guest releases inside
the backend migration because 24.04 is the release proven by both adapters and
remains security-supported. Qualifying 26.04 is a later, independent image
upgrade; Incus publishes multiple distributions and does not choose that policy
for Atlas.

The Canonical OCI artifact is an application-style root filesystem. It does not
contain a bootable system init or Incus image metadata. Incus system containers
expect an operating-system root with init plus an Incus metadata tarball; the
tested image supplies that metadata separately from its rootfs squashfs, as
specified by the [Incus image format](https://linuxcontainers.org/incus/docs/main/reference/image_format/).
This is an image-format and boot-contract mismatch, not evidence that a newer
Ubuntu release works better.

Atlas will therefore:

- keep Ubuntu 24.04 LTS for the first Incus adapter rather than couple the
  backend migration to an OS-major upgrade
- consume an exact fingerprint of the Incus team's Noble system image and
  materialize its metadata and rootfs with pinned hashes
- disable floating alias updates and advance the image deliberately through the
  Atlas contract suite and security review
- treat the Incus daemon LTS and the guest Ubuntu LTS as independent version
  tracks
- decide before physical alpha whether the Linux Containers community image is
  an acceptable production source or Atlas should reproduce the Incus metadata
  around a Canonical-published system root

[Ubuntu 24.04 receives standard security maintenance through May 2029](https://ubuntu.com/about/release-cycle).
Its replacement is a separate lifecycle decision; Incus 7.0 LTS support extends
through June 2031.

## Dependability assessment

Incus is dependable enough for Atlas to adopt behind its own adapter boundary.
The evidence is stronger than the project's young 2023 name suggests because
it is a continuation of the LXD codebase and is maintained by the original LXD
team under the Linux Containers organization.

Current maintenance evidence as of August 31, 2026:

- [GitHub records](https://github.com/lxc/incus/releases) 46 releases from
  October 2023 through Incus 7.4 in August
  2026, including 26 releases since January 2025. The feature track is monthly;
  Atlas will not use that short support window.
- [Incus 7.0 LTS](https://discuss.linuxcontainers.org/t/incus-7-0-lts-has-been-released/26641)
  is supported through June 2031. The first two years receive bug
  and security fixes plus minor usability improvements; the final three years
  receive security fixes.
- The 7.0 release credits 204 contributors since 6.0 and 45 contributors in the
  final 6.23-to-7.0 cycle.
- Incus is independently packaged by
  [Debian](https://wiki.debian.org/Incus),
  [Fedora](https://packages.fedoraproject.org/pkgs/incus), NixOS, Arch, Alpine,
  Gentoo, openSUSE, and other distributions. Debian stable carries the LTS and
  publishes Incus updates through its security archive.
- The [official Terraform/OpenTofu provider](https://registry.terraform.io/providers/lxc/incus/latest)
  reported 877,639 total downloads and
  5,688 downloads in the current week. That is credible evidence of ongoing
  automation use, though it is not a production-install count.
- Commercial support exists through Zabbly for its Debian and Ubuntu packages.

There are also real risks:

- Development is concentrated. The contributor base is broad, but the commit
  history and release work are dominated by a small core, especially Stéphane
  Graber and Thomas Parrott.
- Upstream publishes source releases rather than an official cross-distribution
  binary channel. Atlas depends on NixOS packaging and must own qualification of
  that exact derivation.
- Incus published a substantial set of host-impacting
  [security advisories](https://github.com/lxc/incus/security/advisories) in
  2026. This is evidence of active disclosure and repair, but also means Atlas
  cannot equate an LTS version label with a fully patched build. The pinned
  [Nixpkgs `incus-lts` derivation](https://github.com/NixOS/nixpkgs/blob/5880666fd9eb563038431edb35c2d0aa595884e6/pkgs/by-name/in/incus/lts.nix)
  currently combines 7.0.1 with 20 explicit backported hardening and security
  patches.
- Local access to the administrative socket is root-equivalent. Atlas must keep
  the socket host-only and never delegate it to an environment or ordinary
  client.

The resulting policy is to pin the complete Nixpkgs revision, monitor Incus and
NixOS security updates, qualify patch-set changes promptly, and preserve a deep
backend seam. Atlas adopts Incus's mature mechanism, not its control plane or
authority model.

## Runtime evidence

`nixos/tests/incus-substrate.nix` boots a nested x86_64 NixOS host under KVM and
uses a pinned Ubuntu Noble system image without runtime image-network access.
The hardened proof passed with the NixOS default Incus LTS 7.0.1 package. An
earlier run of the core matrix and reboot contract also passed with Incus 7.3.
Atlas should start on the NixOS LTS track and consume its backported security
patches rather than selecting the feature track for version number alone. The
proof currently validates:

- an Incus Btrfs pool on the elastic Atlas data filesystem
- AppArmor enabled on the host and unprivileged containers with distinct,
  isolated UID maps
- two environments with separate root, process, loopback, and network
  namespaces
- one shifted durable owner-home volume shared across those isolated UID maps
- a dependent per-environment configuration volume that follows root snapshot
  and delete semantics
- ordinary Ubuntu package installation and `/etc` mutation persisting across
  instance restart
- snapshot restore removing later root and dependent-volume changes while
  preserving later writes to the independent durable volume
- delete and recreation removing resettable drift while preserving the durable
  owner volume; observed recreation took 14.6 to 20.3 seconds across KVM runs
- Incus daemon restart leaving both running instances and their process IDs
  intact
- default bridge reachability between environments before policy
- an Incus NIC ACL blocking the other environment, host bridge, RFC 1918 LAN,
  tailnet, and link-local metadata destinations while allowing the intended
  external test destination
- explicit guest IPv6 disablement so link-local IPv6 does not bypass the IPv4
  policy proof
- host reboot autostart, persistent root and volume state, and loss of volatile
  listeners

The test deliberately disables the instance guest API and verifies that neither
the Incus administrative socket nor the guest API socket is present inside an
environment. Host automation forces non-interactive, stdin-disabled `incus
exec`; auto mode repeatedly hung in the NixOS test driver even after the guest
had a valid lease.

## Required NixOS integration

The stock NixOS module was not sufficient by itself in this nested host proof.
The working configuration also needs:

- AppArmor enabled and the Incus AppArmor profile directory created before the
  daemon starts
- host DHCP excluded from the Incus bridge and its `veth` devices
- the Incus bridge trusted by the NixOS host firewall so DHCP and host-bound
  bridge traffic reach Incus's own nftables policy
- nftables rather than legacy iptables
- automation commands with explicit timeouts, hard kill-after bounds, and
  `incus exec -T -n`

These are adapter responsibilities, not configuration that Atlas should expose
to clients.

## Authority boundary

The Incus administrative Unix socket is root-equivalent. Atlas must keep it
host-only and call it from the root-authorized lifecycle mechanism. Environment
processes, ordinary clients, paired controllers, and tailnet members must never
receive that socket or membership in `incus-admin`.

Incus projects and its remote API are not needed for the first adapter. Atlas
should preserve its peer-derived local control protocol and use the local Incus
API as an internal mechanism. Pairing and private routes remain Atlas concerns.

## Qualification gates after selection

1. Define the reproducible, provenance-checked system-image pipeline described
   above. The current proof's pinned image is sufficient for adapter work, not
   yet the physical release provenance decision.
2. Implement an Incus-backed environment through the existing lifecycle seam
   and pass the current Atlas control and installed-host contracts without
   weakening kernel-derived identity or root-only lifecycle authority.
3. Prove update, rollback, backup, restore, power-loss, storage exhaustion, and
   recovery behavior. The current proof covers snapshots and reboot, not those
   failure modes.
4. Decide whether instance limits or storage quotas are required for optional
   additional environments and validate their enforcement at runtime.
5. Re-run the security review against the exact pinned Incus and NixOS patch set
   used by the physical image.

Incus is selected now. These gates determine when it replaces the current
adapter and when the managed physical image can ship; they do not reopen the
substrate decision unless the implementation fails a product contract.
