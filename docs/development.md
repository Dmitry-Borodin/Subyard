# Development

Subyard's control-plane engine is a native Linux Go binary. Shell remains the system-adapter and
safety layer, so contributors need both the Go and shell toolchains.

## Toolchain

`go.mod` is authoritative: the module's minimum language baseline is Go 1.25.6 and its `toolchain`
directive selects Go 1.26.5 for development and CI. A recent Go bootstrap can fetch that toolchain
automatically. CI uses `actions/setup-go` with `go-version-file: go.mod`; it does not carry a second
version constant.

On Debian, install the normal build prerequisites with:

```sh
sudo apt-get update
sudo apt-get install -y golang-go gcc make shellcheck jq
```

Debian 13 currently ships an older bootstrap Go than the Incus client requires. That is acceptable
for source development because Go follows the module's `toolchain` directive. Confirm the selected
compiler with `go version` after the first build.

## Build and test

```sh
make build
./tests/run.sh
```

`make build` writes the ignored `.build/yard` atomically. `bin/yard` is only a source-tree launcher:
it rebuilds a stale engine when a Go compiler is available. `scripts/install-cli.sh` builds first and
atomically installs the native artifact as the ignored `bin/yard-engine`, then links
`~/.local/bin/yard` and `sy` directly to it. Installed/runtime use therefore never downloads a
compiler or module, and `make clean` cannot remove the installed engine.

`make package VERSION=<version>` writes a versioned Linux binary, detached SHA-256 and compatibility
manifest under `.build/release/`. A downloaded artifact is installed atomically with
`scripts/install-engine-release.sh --artifact <file> --checksum <file.sha256>`; the prior binary is
retained as `yard-engine.previous`. `scripts/install-engine-release.sh --rollback` swaps the two
verified executables without a download. State schema compatibility remains fail-closed in the Go
readers, so an unsupported project or credential schema blocks an upgrade/snapshot instead of being
silently rewritten.

`./tests/run.sh` is the single unprivileged gate. It runs formatting, vet, race-enabled Go tests, a
short parser fuzz smoke, the static binary build, and all Bash unit/contract/integration tests. It
does not require root, the host Incus socket, real credentials, systemd, SSH peers, or external
services.

CI additionally installs `openssh-server`, downloads the pinned age/SOPS artifacts through the
checksum-verifying project installer, and runs the temporary loopback contracts under
`tests/real-host/`. Those tests use synthetic payloads and an ephemeral non-system sshd; dedicated
container/VM and two-owner-host acceptance remains an explicit release gate.

The remaining real-host acceptance lane is deliberately small: real Incus container/VM lifecycle,
storage and idmap, NetworkManager/UFW, systemd installation, SOPS/age installation and genuine SSH
peer/remote-yard paths. Those checks use release evidence and are not part of the yard-safe gate.
The exact opt-in official-client command is in
[`real-host-acceptance.md`](real-host-acceptance.md).

On a trusted KVM-capable host, the two-instance portion can run in an opt-in container yard through
[`yard test-vms`](test-vms.md). Its lifecycle and ownership/TTL guards are covered host-free by
`tests/test-vms.sh`; actual VM boot, SSH and cleanup remain a real-host gate.

## Delivery spike

The initial amd64 measurement on Debian 13 (2026-07-20, clean cache after compilation) produced a
3,031,202-byte statically linked core binary. `yard --list` cold start was 2–4 ms and an idle
`yard rpc --stdio` session reported about 4.1–4.3 MiB RSS with no observable background CPU activity. The
bounded official-Incus-client delivery spike linked to 14,074,018 bytes; that adapter is now the
production path for native status/inventory and typed RPC. These
figures are a regression baseline, not release limits; release evidence should repeat them on the
target host.

The switched engine was measured again in the same development class on 2026-07-21: the stripped
amd64 artifact was 14,307,490 bytes, 20 warm `yard --list` process samples had a 13.3 ms median
(7.2–22.5 ms range), and a negotiated idle stdio RPC process used about 11.9 MiB RSS with zero CPU
ticks over one second. The expected step from the core baseline is explained by the official Incus,
HTTP and WebSocket client graph now being linked into the sole production binary. RPC remains
request-driven with no background polling. Real snapshot latency is recorded separately on the
dedicated release host because it depends on a live container/VM and Incus socket.
