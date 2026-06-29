# Subyard

> **A local yard for isolated agent containers.**

Subyard is a local "yard" that runs several **isolated agent containers** for
**development**. One developer runs many coding agents
(Claude Code, Codex, …) in parallel; each works in its own workspace, runs the
full test suite (emulators, build caches, …), and never touches the host.

## Model

- **Yard (L1)** — an isolation layer (an [Incus](https://linuxcontainers.org/incus/)
  instance) that keeps the host clean. Agents and their projects run inside it,
  sharing a persistent `/srv`, writable caches, and narrow host mounts.
- **Two tiers for agents — L1 or L2.** An agent can work **directly in the yard
  (L1)**, or in a **per-project environment container (L2)** built from a
  dependency profile — its own toolchain image, baked from the project's
  Dockerfile. L1 is the default; L2 gives a project a clean, profile-defined box
  *inside* the yard. Either way the agent never touches the host.
- **Generic core + swappable profiles.** The reusable core — isolation, a
  persistent `/srv`, narrow host mounts, a secrets/gateway boundary, the `yard`
  CLI (alias `sy`), snapshots/reset, and VS Code Remote-SSH — does not depend on
  any toolchain. Per-project needs come from a **dependency profile** that
  declares a base image, caches, environment, and devices. Android
  (SDK + Gradle + emulator) is just the first example profile, not the point.
- **Shared resources.** A profile can declare resources shared by every agent in
  the yard instead of each one spinning up its own — for example an on-demand
  emulator pool, or a long-running service the whole yard talks to. `yard status`
  lists them with their state and a bring-up hint.
- **Cheap to fail.** Everything inside the yard is recreatable, snapshot-able,
  and destroyable. Tear a machine down and bring it back.

## Threat model

Subyard protects the **host** (its files and system) from the agents running
inside the yard. The trust boundary is the host: agents are trusted peers of a
single developer, isolated from the machine they run on. Defense-in-depth: an
agent's L2 container sits **inside** the yard, so escaping the container is not
the same as reaching the host.

Subyard does **not** try to hide your provider session from the agents — by
design you may grant agents access to your own session. If you need a stronger
boundary, run the yard as a VM (see below).

## Container or VM

The yard runs as an Incus **system container** by default (shared host kernel,
fast, practical isolation). Set `INSTANCE_TYPE=vm` to run it as an Incus **VM**
instead (separate kernel, stronger boundary, clean nesting for sandbox tests).
The core is switchable without a rewrite.

## Local or remote yard

The yard is reached over SSH — VS Code Remote-SSH for L1, plus Dev Containers
("Reopen/Attach in Container") for L2 boxes. Because access is uniform, a
**remote** yard on another machine is meant to be used exactly like a local one:
point the CLI at a remote SSH target and the workflow is unchanged. This is **not
fully implemented yet** — today the yard runs locally, and remote selection
(`yard remote …`) is planned.

## Repository layout

```
bin/                Host CLI: yard (alias sy) — a dispatcher over scripts/
scripts/            Host + yard lifecycle scripts (00-check-host.sh … 09-yard-extras.sh, init.sh, 99-teardown.sh)
scripts/install-cli.sh  Put yard/sy on your PATH (~/.local/bin) + tab-completion
completions/        Shell tab-completion for yard/sy (bash, zsh)
config/             Settings: subyard.env (instance), incus.project.env (project),
                    host.env (all host paths + host→yard mounts/symlinks),
                    ports.env (host loopback ports for proxy devices, e.g. emulator adb)
config/profiles/    Dependency profiles (android.conf, openclaw.conf; the .conf is the
                    non-secret contract, an optional gitignored sibling .env carries secrets)
```

## Requirements

- A Linux host with hardware virtualization (KVM) for VM mode and the Android
  emulator.
- [Incus](https://linuxcontainers.org/incus/) installed and initialized.

## Getting started

Subyard is built in phases (host check → Incus install → yard instance →
provisioning → profiles → agents → VS Code → snapshots → acceptance). Start by
verifying the host:

```sh
./scripts/00-check-host.sh
```

This repository currently contains the early scaffolding. More to come.
