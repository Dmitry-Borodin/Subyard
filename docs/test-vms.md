# Disposable nested test VMs

`yard test-vms` creates two disposable Incus VMs inside a trusted container yard:

```text
L0 host
└── yard-e2e-yard                 INSTANCE_TYPE=container
    └── inner Incus daemon        NESTED_E2E_VMS=1
        ├── e2e-vm-1              virtual machine
        └── e2e-vm-2              virtual machine
```

The operator controls the inner Incus worker through L0. Agents reach only guest SSH through a
restricted L1 jump account. The inner network is not routed onto L0.

## Enable `e2e-yard`

The public `e2e-vms` profile is dormant. Register it explicitly in
`private/yards/e2e-yard.env` or `~/.config/subyard/yards/e2e-yard.env`:

```sh
YARD_TEMPLATE=e2e-vms
SSH_PORT=2223
```

Prepare the agent identity, then let the operator reconcile the yard:

```sh
dev/agent-e2e.sh --prepare
yard -Y e2e-yard init
```

The private key stays under `~/.subyard/e2e/`. The ignored
`temp/agent-e2e/e2e-yard/` directory contains only the enrollment public key, route and host-key
pins. Without an enrollment request, agent ingress remains disabled.

The outer yard must remain a container. Inner Incus creates `e2e-vm-1` and `e2e-vm-2` as VMs.
Init requires `/dev/kvm`, `/dev/vsock`, `/dev/vhost-vsock` and `/dev/net/tun`, then installs the
inner daemon, bridge, firewall, worker and TTL timer. Neither `dev` nor the agent account belongs
to inner `incus-admin`.

For the AppArmor userspace/kernel mismatch affecting nested QEMU, only the inner daemon uses
`INCUS_SECURITY_APPARMOR=false`. The outer yard AppArmor profile remains active.

## Lifecycle

Only the operator allocates resources:

```sh
yard -Y e2e-yard start
yard -Y e2e-yard test-vms up
# Agent checks run here.
yard -Y e2e-yard test-vms down
yard -Y e2e-yard stop
```

Each VM defaults to a 10 GiB root disk and a 20-hour TTL. `down` refuses unknown instances or
invalid ownership markers. Run it before disabling `NESTED_E2E_VMS`.

## Agent workflow

Run commands from the current dirty public worktree:

```sh
dev/agent-e2e.sh -- COMMAND [ARG...]
dev/agent-e2e.sh --vm 1 -- COMMAND [ARG...]
```

The runner excludes ignored/private data, checks the bundle and removes its guest directory on
exit. It never starts or stops the yard or VMs.

Run the P0 matrix after the operator allocates both VMs:

```sh
dev/e2e/p0-acceptance.sh
```

It covers legacy upgrade, real Incus, rollback, SSH/RPC and cross-owner credential sync.

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
  dev/e2e/seed-test-vms-legacy-state.sh subyard-e2e-yard yard-e2e-yard
./bin/yard -Y e2e-yard init
```

The fixture recreates legacy groups, `root:yard 2770` state and missing agent/firewall setup. It
refuses L0, the outer operator yard and targets without Subyard ownership markers.

## Security boundary

This mode is only for a trusted yard:

- L1 root receives KVM/vsock/TUN devices and required BPF interception;
- L1 `dev` and the agent account cannot access inner Incus or worker state;
- the agent has no L1 shell, PTY, arbitrary forwarding or agent/X11 forwarding;
- guest root cannot reach L1 management services;
- no L0 socket, host path or production credential is passed inward;
- the outer AppArmor boundary remains active.

Normal yards keep `NESTED_E2E_VMS=0`. Use `yard security` to verify the live policy.
