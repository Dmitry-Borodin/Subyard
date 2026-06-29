# Subyard

> **Give agents a yard, not the house keys.**

Subyard is the default backyard for AI coding agents: a full-OS, host-like workspace for any project, where agents can build, test, and propose changes with room to run — without roaming through your laptop, secrets, or deploy controls. One developer runs many coding agents (Pi, OpenCode, Claude Code, Codex, …) in parallel; each works in its own workspace, runs the full test suite (emulators, build caches, …), and never touches the host.

## Model

- **Yard (L1)** — an isolation layer (an [Incus](https://linuxcontainers.org/incus/) instance) that keeps the host clean. Agents and their projects run inside it, sharing a persistent `/srv`, writable caches, and narrow host mounts.
- **Two tiers for agents — L1 or L2.** An agent can work **directly in the yard (L1)**, or in a **per-project environment container (L2)** built from a dependency profile — its own toolchain image, baked from the project's Dockerfile. L1 is the default; L2 gives a project a clean, profile-defined box *inside* the yard. Either way the agent never touches the host.
- **Generic core + swappable profiles.** The reusable core — isolation, a persistent `/srv`, narrow host mounts, a secrets/gateway boundary, the `yard` CLI (alias `sy`), snapshots/reset, and VS Code Remote-SSH — does not depend on any toolchain. Per-project needs come from a **dependency profile** that declares a base image, caches, environment, and devices. The repo ships three (`android`, `default`, `openclaw`); Android (SDK + Gradle + emulator) is just an example, not the point.
- **Shared resources, self-registering.** A profile can declare resources shared by every agent in the yard instead of each one spinning up its own — an on-demand Android emulator, a live staging gateway, a QA-bot broker. Each is a small descriptor (`resources/*.res`) that the `yard` CLI reads at runtime, so the resource shows up as a first-class command (`yard emu`, `yard staging`, …) **without editing the core**. `yard status` lists them with their state and a bring-up hint.
- **Cheap to fail.** Everything inside the yard is recreatable, snapshot-able, and destroyable. Tear a machine down and bring it back.

## Getting started

You need a **Linux host**; `yard init` installs Incus for you. On Windows/macOS, run the yard inside a Linux VM (WSL2/Colima etc.)— native packaging not yet done, ask your agent to add it.

Put the CLI on your PATH, preflight the host, and stand the yard up:

```sh
./scripts/install-cli.sh      # yard + sy on PATH, shell completion
yard check                    # read-only: can this host run a yard?
yard init                     # Incus → project → yard → mounts → provision
```

Then drop a project in and open it:

```sh
yard sync .                   # copy the current project into the yard
yard code .                   # open it in VS Code over Remote-SSH
yard status                   # yard + ssh + mounts + services + projects
```

Run `yard --help` for the full command set (`yard <command> -h` for one). `yard init --reset` does a clean teardown + fresh init.

## The `yard` CLI

Everything goes through one host command, `yard` (alias `sy`) — a thin dispatcher over `scripts/`. Run `yard --help` for the full list; the main groups:

- **Yard lifecycle** — `check` (read-only host preflight), `init` (install Incus → project → yard → mounts → provision), `start` / `stop` / `teardown`, `status`, `logs`, `usage` (coding-agent token usage via ccusage).
- **Projects** — `sync` / `bind` / `clone` a project into the yard, `list`, `code` (open in VS Code over Remote-SSH), `export` (pull a diff back to the host), `remove`, plus `ssh` / `shell` to get a prompt inside.
- **L2 project box** — `up` / `down` / `info` for a project added with `--target <profile>` (build/start/inspect its toolchain container).
- **Profile resources** — commands contributed by the active profiles' `.res` descriptors, e.g. `yard emu` (Android emulator + adb/scrcpy bridge), `yard staging` (live staging gateway), `yard qa-pool` (QA-bot broker). These are discovered at runtime, not hardcoded.

## Threat model

Subyard protects the **host** (its files and system) from the agents running inside the yard. The trust boundary is the host: agents are trusted peers of a single developer, isolated from the machine they run on. Defense-in-depth: an agent's L2 container sits **inside** the yard, so escaping the container is not the same as reaching the host. For a stronger host boundary, run the yard as a VM (see below).

Subyard does **not** hide your provider session from the agents — by design you may grant them access to your own session. That holds in a container or a VM alike; to narrow it, scope what you hand the agent (a separate or limited key, or the secrets/gateway boundary) rather than the isolation layer.

## Container or VM

The yard runs as an Incus **system container** by default (shared host kernel, fast, practical isolation). Set `INSTANCE_TYPE=vm` to run it as an Incus **VM** instead (separate kernel, stronger boundary, clean nesting for sandbox tests). The core is switchable without a rewrite.

## Local or remote yard

The yard is reached over SSH — VS Code Remote-SSH for L1, plus Dev Containers ("Reopen/Attach in Container") for L2 boxes. Because access is uniform, a **remote** yard on another machine is meant to be used exactly like a local one: point the CLI at a remote SSH target and the workflow is unchanged. This is not fully implemented yet — today the yard runs locally, and remote selection (`yard remote …`) is planned.

## Coding agents

The yard is agent-agnostic — Pi, OpenCode, Claude Code, Codex, and friends all run side by side. `config/agents.env` is the per-agent layer: one stanza per agent declaring which default config to lay into the yard (`config/agents/<name>/`) and which session/state paths to persist on the host store so they survive a yard reset. The shipped defaults let an agent work freely *inside* the container (no approval prompt on every read-only command), which is the whole point of the isolation boundary.

## Repository layout

```
bin/                Host CLI: yard (alias sy) — a thin dispatcher over scripts/
scripts/            Host + yard lifecycle (00-check-host.sh … 10-provision-profile.sh,
                    init.sh, 99-teardown.sh), the project-*/yard-* command handlers,
                    profile-resource handlers (yard-emu.sh, project-staging.sh, qa-pool.sh),
                    and shared libs (lib*.sh)
scripts/install-cli.sh  Put yard/sy on your PATH (~/.local/bin) + tab-completion
completions/        Shell tab-completion for yard/sy (bash, zsh)
config/             Settings: subyard.env (instance), incus.project.env (project),
                    host.env (all host paths + host→yard mounts/symlinks),
                    ports.env (host loopback ports for proxy devices, e.g. emulator adb),
                    agents.env (per-agent config + persistence)
config/agents/      Per-agent default configs laid into the yard (claude, codex, pi)
config/profiles/    Dependency profiles, one directory each (android, default, openclaw):
                    profile.conf (non-secret contract), provision.sh, and
                    resources/*.res (shared-resource descriptors). A gitignored
                    sibling .env carries any secrets.
config/staging/     Staging-gateway zone config (canonical.conf + .example templates)
config/qa-pool/     QA-bot broker config (.example templates)
```

