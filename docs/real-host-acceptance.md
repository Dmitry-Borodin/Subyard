# E2E VM acceptance

The default `./tests/run.sh` is host-free. Live acceptance runs only on the two disposable VMs
allocated by the operator with `yard -Y e2e-yard test-vms up`:

```sh
dev/e2e/p0-acceptance.sh
```

The agent does not change allocation lifecycle or work in the privileged outer yard. Never run
these checks on the operator host or a working yard.

## Official Incus client contract

Inside an allocated E2E VM, the server/extensions half can be checked without creating an instance:

```sh
SUBYARD_REAL_INCUS_SOCKET=/var/lib/incus/unix.socket \
go test -tags realincus ./internal/adapters/incusclient -run '^TestRealIncusServerContract$'
```

The full acceptance runner creates its own marked container and VM, then runs:

```sh
SUBYARD_REAL_INCUS_SOCKET=/var/lib/incus/unix.socket \
SUBYARD_REAL_INCUS_CONTAINER_PROJECT=subyard-e2e-container \
SUBYARD_REAL_INCUS_CONTAINER_INSTANCE=yard-e2e-container \
SUBYARD_REAL_INCUS_VM_PROJECT=subyard-e2e-vm \
SUBYARD_REAL_INCUS_VM_INSTANCE=yard-e2e-vm \
bash tests/real-host/incus-contract.sh
```

This checks the same server, instance, async exec, stdio-flush, operation-event delivery and
event-cancellation semantics covered by the fake Unix/WebSocket server. It executes only `printf`
inside each selected running instance.

## Platform and release checks

VM1 installs the candidate runtime, runs `init` twice, repairs a legacy fixture and verifies storage,
network, systemd, Incus container/VM and rollback behavior. VM2 runs the full suite and transport
contracts. Only these disposable VMs observe real KVM and kernel behavior.

Exercise a synthetic project through `sync`, `list --live`, `shell`, `export`, and `remove`; test an
active profile resource through bring-up/status/shutdown. Android emulator process checks must stay
user-scoped and argv-anchored.

The host-free `tests/engine-release.sh` proves engine and full-runtime checksums/provenance,
offline and incomplete-download behavior, atomic upgrade/rollback layout, stdio half-close and
supported/unsupported protocol negotiation. On the E2E lane, install two versioned runtimes on VM1,
connect from VM2 over SSH stdio, upgrade the owner while the controller stays on the previous
version, and then run `yard update --rollback`. The upgrade path
runs `_migrate apply` before switching `current`; rollback checks the retained runtime before swapping
`current` and `previous`.

Use two synthetic credential peers to exercise pinned SOPS/age tooling and the real SSH path:
reciprocal trust, a shared record, an exclusive assignment move, sync, materialization and revoke.
Also exercise a disposable remote yard through its real SSH identity and RPC transport. Repeat cold
CLI startup, idle RPC RSS/CPU, snapshot latency and package-size measurements; compare them with the
host-free baseline in `docs/development.md`. Record results outside the public repository without
host names, credentials or payloads.

Before the two-VM SSH run, verify the exact pinned binaries without fake crypto:

```sh
SUBYARD_KEYS_TOOLS_DIR=/tmp/subyard-real-tools \
SUBYARD_HOME=/tmp/subyard-real-tools-home \
ASSUME_YES=1 scripts/install-key-tools.sh --yes

SUBYARD_REAL_KEYS_TOOLS_DIR=/tmp/subyard-real-tools \
bash tests/real-host/credential-tools.sh
```

The opt-in fixture creates only temporary synthetic peer ledgers, checks that plaintext never enters
them, decrypts through the second peer and verifies revoke materialization. It does not replace the
real SSH peer/exclusive-handoff check.

If OpenSSH server is installed, a non-privileged loopback gate verifies the real SSH handshake,
temporary host/client keys, strict host-key checking and the framed RPC stream without touching the
system daemon:

```sh
bash tests/real-host/ssh-rpc.sh
```

This closes the OpenSSH transport implementation itself; the two-E2E-VM run remains responsible
for routing, disconnect and exclusive-handoff behavior across a real host boundary.

The same ephemeral server can exercise real credential Git/SSH exchange together with the pinned
age/SOPS binaries:

```sh
SUBYARD_REAL_KEYS_TOOLS_DIR=/tmp/subyard-real-tools \
bash tests/real-host/ssh-credential-peer.sh
```

It verifies reciprocal trust roles, the retained SSH route, signed encrypted sync, remote decrypt,
plaintext isolation and revoke. The two-E2E-VM lane still verifies host identity separation,
failure/reconnect and an exclusive handoff with real consumers.
