# Disposable nested test VMs

`yard test-vms` creates two disposable Incus VMs inside a trusted container yard:

```text
L0 host
└── yard-test-yard                INSTANCE_TYPE=container
    └── inner Incus daemon        NESTED_E2E_VMS=1
        ├── e2e-vm-1              virtual machine
        └── e2e-vm-2              virtual machine
```

The operator controls the inner Incus worker through L0. Agents reach only guest SSH through a
restricted L1 jump account. The inner network is not routed onto L0.

## Enable `test-yard`

The public `test-vms` profile is dormant. Register it explicitly in
`private/yards/test-yard.env` or `~/.config/subyard/yards/test-yard/config.env`:

```sh
YARD_TEMPLATE=test-vms
SSH_PORT=2223
```

Prepare the agent identity in the worktree that will run tests:

```sh
dev/agent-e2e.sh --prepare
```

The private key stays under `~/.subyard/e2e/`. The ignored
`temp/agent-e2e/test-yard/` directory contains only the enrollment public key, route and host-key
pins. Without an enrollment request, agent ingress remains disabled.

When that worktree is already on L0, the operator can reconcile it with:

```sh
yard -Y test-yard init
```

When the worktree and Codex run inside a normal developer yard, L0 cannot read that checkout through
its immutable runtime. The operator instead bridges the fixed public artifacts through the registered
project:

```sh
yard -Y test-yard test-vms enroll --project Subyard
```

The command reads only `temp/agent-e2e/test-yard/agent-access.pub`, shows the Ed25519 fingerprint and
an exact plan, and asks once. It stores the active single-controller enrollment under the L0 Subyard
data home, reconciles access in the already running lab without starting or stopping a yard or VM,
then returns only `route.tsv` and `known_hosts` to the same project. Private agent, Git and Codex
credentials never cross the boundary. Versioned private configuration sync does not manage this
runtime access state.

To revoke that controller while keeping the allocation running:

```sh
yard -Y test-yard test-vms enroll --project Subyard --revoke
```

The outer yard must remain a container. Inner Incus creates `e2e-vm-1` and `e2e-vm-2` as VMs.
Init requires `/dev/kvm`, `/dev/vsock`, `/dev/vhost-vsock` and `/dev/net/tun`, then installs the
inner daemon, bridge, firewall, worker and TTL timer. Neither `dev` nor the agent account belongs
to inner `incus-admin`.

For the AppArmor userspace/kernel mismatch affecting nested QEMU, only the inner daemon uses
`INCUS_SECURITY_APPARMOR=false`. The outer yard AppArmor profile remains active.

## Lifecycle

Only the operator allocates resources:

```sh
yard -Y test-yard start
yard -Y test-yard test-vms up
# Agent checks run here.
yard -Y test-yard test-vms down
yard -Y test-yard stop
```

Each VM defaults to a 10 GiB root disk, a host-aware automatic vCPU limit, and a 20-hour TTL. Set a
numeric `E2E_VM_CPU` in the yard definition to override the CPU limit explicitly. `down` refuses
unknown instances or invalid ownership markers. Run it before disabling `NESTED_E2E_VMS`.

## Agent workflow

Run commands from the current dirty public worktree:

```sh
dev/agent-e2e.sh -- COMMAND [ARG...]
dev/agent-e2e.sh --vm 1 -- COMMAND [ARG...]
```

The runner excludes ignored/private data, checks the bundle and removes its guest directory on
exit. It never starts or stops the yard or VMs. It targets `test-yard` by default. During a
temporary migration, select the old yard explicitly with `--yard e2e-yard`; each yard has separate
route and generated SSH state, while the controller identity remains shared.

Run the P0 matrix after the operator allocates both VMs:

```sh
dev/e2e/p0-acceptance.sh
```

It covers legacy upgrade, real Incus, rollback, SSH/RPC and cross-owner credential sync. Before
provisioning, the lane rejects product or pool roots backed by tmpfs, insufficient root
disk/inodes, or an undersized `/tmp` transient area. Heavy run-owned state and the disposable Go
build cache live under a marker-owned `$HOME/.cache/subyard-p0-<allocation>/` root; the Go
module/toolchain cache remains reusable across runs.

The final report records measured peak root-disk, inode, tmpfs and RAM use for each VM. Cleanup
then proves that the exact P0 state root, fixture releases/users, Incus projects and temporary
pools are gone. The allocation, TTL, reusable module cache and allocation-level Incus image cache
are not removed.

Direct guest access:

```sh
dev/agent-e2e.sh --ssh 1
dev/agent-e2e.sh --ssh 2 -- sudo -n id -u
dev/agent-e2e.sh --verify-boundary

config="$(dev/agent-e2e.sh --ssh-config)"
ssh -F "$config" e2e-vm-1
```

The jump account returns read-only allocation status and forwards only to the two guest SSH ports.
One controller key authenticates to both guests; each guest has its own pinned host key and
VM-local peer identity. No operator or production credential enters a VM.

### Legacy upgrade

VM1 must test old state before current `yard init`:

```sh
SUBYARD_E2E_LEGACY_FIXTURE=1 \
  dev/e2e/seed-test-vms-legacy-state.sh subyard-test-yard yard-test-yard
./bin/yard -Y test-yard init
```

The fixture recreates legacy groups, `root:yard 2770` state and missing agent/firewall setup. It
refuses L0, the outer operator yard and targets without Subyard ownership markers.

## Migrate or remove an old `e2e-yard`

`e2e-vms` is retired and is not a compatibility alias. If an existing registration still selects
it, the CLI fails closed and prints that registration's exact path. Replace only its template
assignment:

```sh
YARD_TEMPLATE=test-vms
```

This does not rename or rebuild the existing yard. Verify it read-only before using its lifecycle:

```sh
yard -Y e2e-yard check
yard -Y e2e-yard status
```

`e2e-yard` and `test-yard` may coexist temporarily when they use distinct `SSH_PORT` values. The
old runner target is always explicit:

```sh
dev/agent-e2e.sh --yard e2e-yard --ssh-config
```

After the new yard has passed acceptance, remove the old one explicitly. The registration must
already use `YARD_TEMPLATE=test-vms`, because teardown never depends on the retired alias:

```sh
yard -Y e2e-yard status
yard -Y e2e-yard test-vms status
yard -Y e2e-yard test-vms down
yard -Y e2e-yard teardown
```

Then remove `e2e-yard.env` and its yard-scoped ignored route/state artifacts. Keep
`~/.subyard/e2e/id_ed25519` while `test-yard` uses that controller identity.

## Security boundary

This mode is only for a trusted yard:

- L1 root receives KVM/vsock/TUN devices and required BPF interception;
- L1 `dev` and the agent account cannot access inner Incus or worker state;
- the agent has no L1 shell, PTY, arbitrary forwarding or agent/X11 forwarding;
- guest root cannot reach L1 management services;
- no L0 socket, host path or production credential is passed inward;
- the outer AppArmor boundary remains active.

Normal yards keep `NESTED_E2E_VMS=0`. Use `yard security` to verify the live policy.
