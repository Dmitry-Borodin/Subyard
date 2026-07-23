# Subyard

> Give agents a yard, not the house keys.

Subyard gives AI coding agents a persistent Linux workspace isolated from the
host by default. It runs an unprivileged Incus instance (the **yard**) and
exposes the workflow through one `yard` CLI.

## Model

- **L1 — Yard:** the persistent Incus container where agents and projects live.
- **L2 — Project environment:** an optional Docker Compose stack selected by a
  project profile.
- **Profiles:** reusable project and agent configuration under `config/`.

`yard sync` copies a project into yard-owned storage. `yard bind` may instead
mount any host directory explicitly; the CLI warns because this weakens the
yard's encapsulation.

## Quick start

Subyard targets a Linux amd64 or arm64 host with Incus. The installer downloads a verified,
self-contained release runtime, so the operator CLI does not require Go or compile source at runtime.
It links `yard` and `sy` into `~/.local/bin` and enables shell completion.

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://github.com/Dmitry-Borodin/Subyard/releases/latest/download/subyard-install.sh | bash
yard check
yard init

yard sync .
yard code .
yard status
```

Run `yard --help` or `yard <command> --help` for complete command usage.
See the [control-plane architecture](docs/control-plane.md) for module ownership, stable extension
contracts, test topology, and the real-host acceptance lane.

## Everyday commands

```text
yard start | stop                  Manage the yard instance
yard security                      Audit the host boundary
yard sync | bind | clone           Add a project
yard list                          List projects
yard shell | code [project]        Open a project session
yard export | remove [project]     Copy out or remove a project
yard provision [profile]           Apply a project profile
yard test-vms <command>            Manage two disposable nested test VMs (opt-in)
yard up | down | info [project]    Manage an L2 project environment
yard keys <command>                Manage the host-side encrypted credential ledger
```

## Multiple and remote yards

Use `-Y` or `@name` to select a named yard. A yard can also point to a host
reached over SSH:

```bash
yard -Y openclaw init
yard @openclaw status

yard remote add srv1 me@srv1
yard -Y srv1 sync .
yard -Y srv1 code .
```

Remote yards support `sync` and `clone`; `bind` is local-only. Yard definitions live in
`config/yards/`. See
[yard configuration](config/yards/README.md) and the [credential ledger](docs/keys.md).

## Security boundary

The yard is an unprivileged container by default. Managed host mounts must stay
under that yard's `HOST_BASE`, while an explicit `yard bind` grants the selected
host path to the yard. Host Docker and Incus control sockets are rejected by
managed configuration. Run `yard security` to audit the effective setup.

A trusted test yard can opt in to two disposable nested VMs without receiving the
L0 Incus socket. See [Disposable nested test VMs](docs/test-vms.md) for the widened
device/syscall boundary, lifecycle and cleanup contract.

Subyard protects the host boundary. It does not isolate credentials between
agents operating inside the same yard.
