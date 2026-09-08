# Paired operator control: local approval registry

This first implementation slice records host-local approval of controller
public keys. It does not expose remote control, authenticate a network peer,
install SSH authorized keys, or terminate remote sessions. A registry entry is
not proof of possession of its private key. Tailnet membership grants no Atlas
authority.

## Host-local ceremony

Host root uses the existing root-only management socket:

```sh
atlas controller pair laptop --public-key-file /path/to/controller.pub --json
atlas controller list --json
atlas controller revoke CONTROLLER_ID --json
```

The operator must independently verify which device supplied the public key
before approval. Only a single OpenSSH Ed25519 public key is accepted; comments
are discarded. Private keys stay on the controller. Pairing never generates or
copies a private key, and approval is not inferred from a name or address.

The ID is the lowercase hexadecimal SHA-256 digest of the SSH public-key blob,
not the OpenSSH `SHA256:` display fingerprint. Names are labels, not authority.
Approving the same active name and key is idempotent. An active name or key
cannot silently be replaced: revoke its existing approval first.

Revocation retains a tombstone and advances the record's generation. Explicit
re-pairing of a revoked key advances it again. Repeated revocation is idempotent.
The last controller can be revoked because host-local root remains the recovery
authority. No browser profile or credential migration is implied.

Records are atomically persisted under `/var/lib/atlas/controllers`, with a
root-only directory and files. Concurrent writers share a lock; a busy or corrupt
registry fails closed. Public and environment sockets cannot list or modify it,
including for environment-local root.

## Next proof

A private transport must authenticate possession of an approved key, bind the
peer to this host's registry, and check active status and generation on every
authorized request. Revocation must fence outstanding requests and sessions;
re-pairing must not revive old sessions. Transport authentication, private
reachability, session fencing, and fresh operator verification remain unbuilt.
Do not describe this local registry as completed remote pairing or browser
takeover support.
