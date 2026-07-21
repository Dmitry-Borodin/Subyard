# Disposable nested test VMs

`yard test-vms` provides exactly two short-lived Incus VMs **inside** an explicitly trusted
container yard. It is intended for real OS, SSH, systemd and multi-owner acceptance that cannot be
proved by host-free contracts.

The topology is:

```text
L0 host
└── yard-e2e-yard                 INSTANCE_TYPE=container
    └── inner Incus daemon        enabled by NESTED_E2E_VMS=1
        ├── e2e-vm-1              virtual machine
        └── e2e-vm-2              virtual machine
```

The inner Incus daemon also owns the managed bridge used by both VMs. The agent connects from the
yard to each VM over that inner network. When the command is invoked on the owner host, the CLI
enters the yard and runs the same worker there; it does not route the VM network onto L0.

## Enable the `e2e-yard` trusted yard

The VM settings are a public but dormant yard profile. They are never loaded for the default yard or
merely because the repository was checked out. Register `e2e-yard` on an explicitly selected
operator machine by creating `private/yards/e2e-yard.env` or
`~/.config/subyard/yards/e2e-yard.env` with:

```sh
YARD_TEMPLATE=e2e-vms
SSH_PORT=2223
```

The public profile supplies only generic VM settings. The registry file supplies the machine-local
activation and unique port without duplicating those settings. Selecting this yard and confirming
`yard -Y e2e-yard init` opts that machine into the wider nested-VM boundary.

The outer `e2e-yard` deliberately remains a container. `NESTED_E2E_VMS=1` provisions the inner
Incus daemon there; that daemon creates the fixed virtual machines `e2e-vm-1` and `e2e-vm-2` with
the Incus `--vm` flag. Setting `INSTANCE_TYPE=vm` would instead make the outer yard itself a VM and
is rejected for this nested test mode.

Then reconcile it from the owner host:

```sh
yard -Y e2e-yard init
```

The host preflight fails before mutation unless `/dev/kvm`, `/dev/vsock`,
`/dev/vhost-vsock` and `/dev/net/tun` are character devices. Init then:

- allows only the device-cgroup BPF interception needed by nested Incus;
- passes those four devices into the L1 container;
- installs Incus 6.0 LTS, QEMU, Go and ShellCheck inside the trusted developer yard;
- creates an inner dir pool and managed NAT bridge;
- installs the fixed lifecycle worker and a TTL cleanup timer;
- grants the yard's `dev` user `incus-admin` access to the **inner** daemon.

On hosts combining AppArmor 4.1 userspace with a 6.8 outer kernel, the fine-grained AF_UNIX policy
compiled for QEMU can be rejected because the parser and kernel disagree on socket type/protocol
encoding. Incus then cannot create its mandatory SPICE socketpair. The provisioner uses Incus'
documented `INCUS_SECURITY_APPARMOR=false` server switch for the **inner daemon only**. The inner
daemon is already root-equivalent to the trusted yard user and controls only this disposable lab;
the outer `yard-e2e-yard` AppArmor profile remains active and continues to enforce the L0 boundary.
The restricted VM project therefore needs no `raw.apparmor` or low-level configuration allowance.

Changing the non-live boundary settings requires a yard restart. The normal SSH/VS Code activity
guard refuses that restart while a session is connected; close the remote session and rerun init.

## Use and remove the lab

Allocation is an operator decision. The operator starts the trusted outer yard, creates the two
VMs, and later removes them and stops the yard. An agent may use an already allocated lab and copy
the candidate under test into it, but must not invoke `up`, `down`, `start` or `stop` itself.

Named yards are stopped after initialization by default. The complete operator lifecycle is:

```sh
yard -Y e2e-yard start
yard -Y e2e-yard test-vms up
# The agent now delivers and tests its candidate without changing allocation state.
yard -Y e2e-yard test-vms down
yard -Y e2e-yard stop
```

After `up` reports both VMs ready, the agent owns `status`, candidate delivery and all test/exec
operations. Those commands also work from a checkout opened inside the trusted yard. SSH uses a
synthetic key created for this lab, pins each VM host key, logs in as `dev`, and provides
passwordless `sudo` inside the VMs. Guest interface names are discovered from Incus network state;
the worker does not assume that the guest preserves the Incus device name `eth0`. Debian 13 also
requires the synthetic account not to be shadow-locked before OpenSSH accepts its public key. The
worker uses an intentionally invalid password-hash marker for that purpose and verifies that SSH
password authentication remains disabled. No host or production credential is copied.

For cross-owner checks, each VM generates its own lab-only Ed25519 identity. The trusted inner
Incus control plane exchanges only their public client keys and reads each VM's public SSH host key
directly from the guest. Both directions are then pinned and smoke-tested. Private peer keys never
leave the VM that created them, and no operator key is copied into either VM.

Candidate delivery must not assume that a cloud image enables the SFTP subsystem. The agent runner
uses an SSH byte stream with an explicit checksum rather than ordinary SFTP-mode `scp`.

Agents run arbitrary checks from the current dirty public worktree with:

```sh
scripts/agent-e2e.sh -- COMMAND [ARG...]
scripts/agent-e2e.sh --vm 1 -- COMMAND [ARG...]
```

The script requires an already allocated lab, copies the same worktree to the selected VM or both,
sets `SUBYARD_E2E_VM` to `1` or `2`, streams command output, and removes its run-specific guest
directories even when a check fails. It never invokes allocation lifecycle commands.

`up` creates a restricted inner project with a hard limit of two VMs and aggregate CPU/RAM limits.
Each VM receives a 10 GiB root disk by default. A clean Debian guest leaves about 9 GiB available,
above Subyard's 5 GiB base-yard preflight floor.
Both instances and the project carry a Subyard ownership marker. A failed `up` writes bounded
diagnostics to the lab state directory and leaves the partial allocation in place for inspection;
only the operator's `down` or the TTL cleaner removes it. `down` refuses cleanup if the project
contains an unexpected instance or a marker does not match; after explicitly deleting the two known
VMs, it uses a normal non-interactive project deletion that fails if any other resource remains.

Run `down` before disabling `NESTED_E2E_VMS`.

## Security boundary

This mode deliberately widens the L0/L1 boundary and must not be enabled for an untrusted yard:

- KVM and vsock devices become reachable by root inside the yard;
- device-cgroup eBPF calls are intercepted by the L0 Incus daemon;
- the yard user receives root-equivalent control of the inner Incus daemon;
- per-instance AppArmor profiles are disabled in that inner daemon to avoid the nested
  parser/kernel ABI mismatch; the outer yard profile remains enforced.

It does **not** pass the L0 Incus Unix socket, host Docker socket, host paths, production keys or
other yard projects. Normal yards retain the stricter default because `NESTED_E2E_VMS=0` explicitly
blocks syscall interception and removes the vsock devices. `yard security` verifies the selected
policy against live Incus state.
