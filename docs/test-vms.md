# Agent E2E VM pool

The `test-vms` profile runs a root-owned lease broker inside a trusted outer yard. The default pool
has two slots. Each slot owns an isolated inner Incus project, network and a retained pair of VMs.
The VM disks survive release; the pair is stopped whenever it has no lease.

The outer yard remains operator-owned. Agents can acquire inner slots, but cannot start a stopped
outer yard, enter its shell, reach its Incus socket or invoke arbitrary lifecycle commands.

## Operator setup

Register a yard with the profile:

```env
YARD_TEMPLATE=test-vms
SSH_PORT=2223
```

Then initialize it interactively:

```sh
yard -Y test-yard init
yard -Y test-yard status
yard -Y test-yard test-vms status
```

A fresh yard with the effective `test-vms` capability starts with desired power `running`. Later
`yard -Y test-yard stop` and `start` persist the normal managed power intent. Agent acquire never
changes it. Stopping the outer yard drains all active slots before shutdown.

`E2E_VM_SLOT_COUNT` defaults to `2` and may be overridden through normal yard/operator config
precedence. Each slot consumes two VMs. Increasing the count adds empty slots; the VMs are created
only on first acquire. Shrink is fail-closed while a retiring slot is held, provisioning, draining
or quarantined. Retained resources are removed only by the confirmed operator configuration
reconcile, never by lease release or age-based GC.

The other physical defaults are:

```env
E2E_VM_IMAGE=images:debian/13/cloud
E2E_VM_CPU=auto
E2E_VM_MEMORY=4GiB
E2E_VM_DISK=20GiB
E2E_VM_BOOT_TIMEOUT=300
```

## Agent workflow

Prepare the persistent controller identity once:

```sh
dev/agent-e2e.sh --prepare
```

If the worktree runs inside a normal developer yard, the L0 operator enrolls its published
controller key:

```sh
yard -Y test-yard test-vms enroll --project Subyard
```

The command reads the fixed public-key request, shows its Ed25519 fingerprint and asks for
confirmation. It returns the route and host-key pins to that project. The enrolled controller key
receives only the versioned forced facade (`status/acquire/renew/release`); it never receives an L1
shell, PTY, file transfer, arbitrary forwarding or Incus access.

Inspect the redacted pool without acquiring:

```sh
dev/agent-e2e.sh --status
```

Run against both VMs of one automatically selected slot:

```sh
dev/agent-e2e.sh -- ./tests/run.sh
dev/agent-e2e.sh --wait 20m -- ./tests/run.sh
dev/e2e/p0-acceptance.sh
dev/agent-e2e.sh --vm 1 -- ./tests/some-real-host-check.sh
```

Open an unrestricted root guest session or run a root command:

```sh
dev/agent-e2e.sh --ssh 1
dev/agent-e2e.sh --ssh 2 -- id -u
```

The wrapper creates an ephemeral Ed25519 key per lease, starts a keeper that renews once per minute,
and releases in its exit trap. Ten minutes without a successful heartbeat expires the lease. With
no `--wait`, an exhausted pool returns a distinct busy exit; `--wait` retries with a bounded timeout.
The raw OpenSSH config and lease capability are internal temporary files and are not an agent API.

## Lifecycle and fencing

Acquire atomically reserves an `available` slot as `provisioning`, then the root broker creates or
starts its pair. Only after both guests are ready does the broker install the ephemeral guest key,
open forwarding through that slot's dedicated data account and publish `held`.

Release, heartbeat expiry, operator drain or outer stop:

1. removes the data-account forwarding key and kills that account's sessions;
2. removes the ephemeral key from both guest root accounts;
3. stops both VMs;
4. publishes `available` only after stop is verified.

Provisioning, fencing or stop failure makes only that slot `quarantined`. Its disks remain for
diagnosis and it is never handed to another caller. Lease identity is fenced by slot generation,
lease epoch, lease ID and a server-side capability verifier; old credentials cannot revive after
release or reuse.

## Isolation boundary

Every slot has its own restricted inner project and managed network. Guest root can use public
Internet egress for package installation, but forwarding between slot networks is denied. Guests
cannot reach L1 management, L0/private/metadata networks, the broker, its state/socket or inner
Incus. A normal development yard may still run its own L1-local Incus containers; it does not
receive the `NESTED_E2E_VMS=1` devices and policy required to run the operator-owned nested VM pool.

Run the negative transport checks after changes to enrollment, routing or SSH policy:

```sh
dev/agent-e2e.sh --verify-boundary
```

The operator owns outer `start`, `stop` and teardown. Agents use only leases allocated by the
broker. An unavailable outer yard produces the stable `test environment unavailable` error instead
of attempting recovery.

## Legacy migration

The old single-pair allocation manifest, static guest forwarding and VM-age TTL are not
normal paths. Upgrade validation accepts an existing pair only after its ownership marker and exact
inventory are checked; foreign resources are never adopted. Existing enrollment state remains the
controller admission gate. Retired `e2e-vms` profile configuration must first be migrated to
`YARD_TEMPLATE=test-vms`; an old `e2e-yard` identity may coexist temporarily and is removed only by
an explicit operator teardown.
