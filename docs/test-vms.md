# Disposable nested test VMs

`yard test-vms` provides exactly two short-lived Incus VMs **inside** an explicitly trusted
container yard. It is intended for real OS, SSH, systemd and multi-owner acceptance that cannot be
proved by host-free contracts.

The topology is:

```text
L0 owner host
└── L1 container yard
    ├── inner Incus daemon + managed bridge
    ├── e2e-vm-1
    └── e2e-vm-2
```

The agent connects from the yard to each VM over the inner managed network. When the command is
invoked on the owner host, the CLI enters the yard and runs the same worker there; it does not route
the VM network onto L0.

## Enable one trusted yard

Keep the public default off. Add the opt-in to that yard's private or machine-local definition:

```sh
NESTED_E2E_VMS=1
E2E_VM_CPU=2
E2E_VM_MEMORY=4GiB
E2E_VM_TTL_MINUTES=240
```

Then reconcile it from the owner host:

```sh
yard -Y <name> init
```

The host preflight fails before mutation unless `/dev/kvm`, `/dev/vsock`,
`/dev/vhost-vsock` and `/dev/net/tun` are character devices. Init then:

- allows only the device-cgroup BPF interception needed by nested Incus;
- passes those four devices into the L1 container;
- installs Incus 6.0 LTS and QEMU inside the yard;
- creates an inner dir pool and managed NAT bridge;
- installs the fixed lifecycle worker and a TTL cleanup timer;
- grants the yard's `dev` user `incus-admin` access to the **inner** daemon.

Changing the non-live boundary settings requires a yard restart. The normal SSH/VS Code activity
guard refuses that restart while a session is connected; close the remote session and rerun init.

## Use and remove the lab

```sh
yard -Y <name> test-vms up
yard -Y <name> test-vms status
yard -Y <name> test-vms ssh 1
yard -Y <name> test-vms exec 2 -- sudo systemctl status ssh
yard -Y <name> test-vms down
```

The same commands work from a checkout opened inside that yard. SSH uses a synthetic key created
for this lab, pins each VM host key, logs in as `dev`, and provides passwordless `sudo` inside the
VMs. No host or production credential is copied.

`up` creates a restricted inner project with a hard limit of two VMs and aggregate CPU/RAM limits.
Both instances and the project carry a Subyard ownership marker. A partial `up` is cleaned
automatically. `down` refuses a force-delete if the project contains an unexpected instance or a
marker does not match. The in-yard systemd timer performs the same guarded cleanup after the TTL.

Run `down` before disabling `NESTED_E2E_VMS`.

## Security boundary

This mode deliberately widens the L0/L1 boundary and must not be enabled for an untrusted yard:

- KVM and vsock devices become reachable by root inside the yard;
- device-cgroup eBPF calls are intercepted by the L0 Incus daemon;
- the yard user receives root-equivalent control of the inner Incus daemon.

It does **not** pass the L0 Incus Unix socket, host Docker socket, host paths, production keys or
other yard projects. Normal yards retain the stricter default because `NESTED_E2E_VMS=0` explicitly
blocks syscall interception and removes the vsock devices. `yard security` verifies the selected
policy against live Incus state.
