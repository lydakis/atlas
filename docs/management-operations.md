# Management operation receipts

Reset and snapshot mutations are host management transitions, not agent tasks.
They must not depend on the lifetime of an SSH connection or control API process.
Ordinary environment use and reboot do not require these receipts or knowledge
of the container substrate.

## Local interface

On the root-only management socket, a reset or snapshot mutation returns an
operation receipt with `id`, `environmentId`, and `status`. The caller can use
`operation.inspect` with that `id` to retrieve the saved state and, once known,
the original operation response. Public and environment sockets do not expose
this interface. Tailnet membership confers no authority.

The CLI polls for up to 30 seconds by default and prints the ordinary result
when the operation finishes within that period. Otherwise it prints a receipt.
`--no-wait` returns the receipt immediately; `--wait` explicitly waits for the
saved outcome. For example:

```sh
atlas environment reset shared-dev --no-wait --json
atlas operation inspect OPERATION_ID --json
```

Receipt states are `pending`, `running`, `succeeded`, `failed`, and `unknown`.
An accepted receipt is not a claim that reset or restore succeeded. A client
should inspect its existing receipt, not resubmit a timed-out mutation.

If polling fails after acceptance, the CLI exits nonzero with
`operation_poll_failed` and the operation ID. JSON output also includes the
last observed `receipt`; its status is not a fresh observation. The worker is
not cancelled or resubmitted. Reconnect and inspect that same ID.

## Execution and recovery boundary

The NixOS adapter runs each accepted transition in an independent root-owned
systemd worker. Restarting the control API does not terminate that worker.
Receipts and admission records live in the root-only directory
`/var/lib/atlas/operations`. Workers continue using the existing environment
lock and reconciliation lock. Python lifecycle entry and generated shell
reconciliation also check the admission record, including between admission
and worker startup.

A pending worker may be started again under the same identity. Once its receipt
has entered `running`, it is never automatically replayed. Completion is saved
before admission is released. Inspecting a completed receipt can finish cleanup
if the worker was interrupted between those steps.

If a started worker disappears without saving its result, inspection reports
`unknown` and keeps conflicting mutations blocked. Ambiguous Incus errors also
retain this restriction. The adapter does not pretend that a disconnected CLI
cancelled a server-side operation. It does not require a host reboot or blindly
retry a destructive action.

Automatic reconciliation of an unknown outcome against Incus operations is
not implemented yet. A genuine worker failure or interrupted host shutdown can
therefore require operator investigation. Do not delete admission records or
retry mutations until the underlying activity and environment state have been
established. This is an explicit remaining recovery gap, not the normal path
for a slow operation or control-service restart.
