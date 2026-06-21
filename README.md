# Subyard

> **A local yard for isolated agent machines.**

Subyard is a local "yard" that runs several **isolated agent machines** for
**development**. One developer runs many coding agents
(Claude Code, Codex, …) in parallel; each works in its own machine, runs the
full test suite (emulators, build caches, …), and never touches the host.

## Model

- **Yard** — an isolation layer (an [Incus](https://linuxcontainers.org/incus/)
  instance) that keeps the host clean. Inside it live several **agent machines**
  (dev containers), one per agent.
- **Generic core + swappable profiles.** The reusable core — isolation, a
  persistent `/srv`, narrow host mounts, a secrets/gateway boundary, agent
  containers, the `yard` CLI (alias `sy`), snapshots/reset, and VS Code Remote-SSH — does not
  depend on any toolchain. Per-project needs come from a **dependency profile**
  that declares a base image, caches, environment, and devices. Android
  (SDK + Gradle + emulator) is just the first example profile, not the point.
- **Cheap to fail.** Everything inside the yard is recreatable, snapshot-able,
  and destroyable. Tear a machine down and bring it back.

## Threat model

Subyard protects the **host** (its files and system) from the agents running
inside the yard. The trust boundary is the host: agents are trusted peers of a
single developer, isolated from the machine they run on. Defense-in-depth: each
agent's dev container sits **inside** the yard, so escaping a container is not
the same as reaching the host.

Subyard does **not** try to hide your provider session from the agents — by
design you may grant agents access to your own session. If you need a stronger
boundary, run the yard as a VM (see below).

## Container or VM

The yard runs as an Incus **system container** by default (shared host kernel,
fast, practical isolation). Set `INSTANCE_TYPE=vm` to run it as an Incus **VM**
instead (separate kernel, stronger boundary, clean nesting for sandbox tests).
The core is switchable without a rewrite.

## Repository layout

```
bin/                Host CLI: yard (alias sy) — a dispatcher over scripts/
scripts/            Host + yard lifecycle scripts (00-check-host.sh … 07-ssh-access.sh, setup.sh)
scripts/install-cli.sh  Put yard/sy on your PATH (~/.local/bin) + tab-completion
completions/        Shell tab-completion for yard/sy (bash, zsh)
config/             Environment + ports (subyard.env, incus.project.env)
config/profiles/    Dependency profiles (android.env, openclaw.env)
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
