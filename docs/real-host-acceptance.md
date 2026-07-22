# Real-host acceptance

The default `./tests/run.sh` is intentionally host-free. Run this smaller opt-in lane only on
dedicated `e2e-*` yards before a release that changes Incus, kernel, network, systemd, credential
transport, or update boundaries. Never point destructive lifecycle checks at a working yard.

## Official Incus client contract

The server/extensions half can be checked independently on any real daemon without creating an
instance:

```sh
SUBYARD_REAL_INCUS_SOCKET=/var/lib/incus/unix.socket \
go test -tags realincus ./internal/adapters/incusclient -run '^TestRealIncusServerContract$'
```

Create or select one running acceptance container and one VM, then run:

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

For both dedicated instance types, run `yard -Y <context> init` twice, introduce one safe managed
drift, and verify that the next run repairs it. Check storage/mount/idmap, NetworkManager/UFW and
desired power across reboot. Use injected KVM facts in host-free tests; only this lane observes the
real `/dev/kvm` and kernel behavior.

Exercise a synthetic project through `sync`, `list --live`, `shell`, `export`, and `remove`; test an
active profile resource through bring-up/status/shutdown. Android emulator process checks must stay
user-scoped and argv-anchored.

The host-free `tests/engine-release.sh` already proves engine and full-runtime checksums/provenance,
offline and incomplete-download behavior, atomic upgrade/rollback layout, stdio half-close and
supported/unsupported protocol negotiation. On the real lane, install two versioned runtimes on a
dedicated owner, connect from a second controller over SSH stdio, upgrade the owner while the
controller stays on the previous version, and then run `yard update --rollback`. The upgrade path
runs `_migrate apply` before switching `current`; rollback checks the retained runtime before swapping
`current` and `previous`.

Use two synthetic credential peers to exercise pinned SOPS/age tooling and the real SSH path:
reciprocal trust, a shared record, an exclusive assignment move, sync, materialization and revoke.
Also exercise a dedicated remote yard through its real SSH identity and RPC transport. Repeat cold
CLI startup, idle RPC RSS/CPU, snapshot latency and package-size measurements; compare them with the
host-free baseline in `docs/development.md`. Record results outside the public repository without
host names, credentials or payloads.

Before the two-host SSH run, verify the exact pinned binaries locally without fake crypto:

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

This closes the OpenSSH transport implementation itself; the two-owner-host run remains responsible
for routing, disconnect and exclusive-handoff behavior across a real host boundary.

The same ephemeral server can exercise real credential Git/SSH exchange together with the pinned
age/SOPS binaries:

```sh
SUBYARD_REAL_KEYS_TOOLS_DIR=/tmp/subyard-real-tools \
bash tests/real-host/ssh-credential-peer.sh
```

It verifies reciprocal trust roles, the retained SSH route, signed encrypted sync, remote decrypt,
plaintext isolation and revoke. The dedicated two-host lane still verifies host identity separation,
failure/reconnect and an exclusive handoff with real consumers.
