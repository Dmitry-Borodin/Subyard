# Devcontainer — `openclaw` profile

The `openclaw` profile's devcontainer, alongside its contract in
[`profile.conf`](../profile.conf): `profile.conf` says *what toolchain* an agent
machine needs; this is the ready-to-use `.devcontainer/` that delivers it for the
"Reopen in Container" flow (`yard code .` → Remote-SSH into the yard → Reopen in
Container).

A profile uses the devcontainer in its own folder if present; otherwise it falls
back to `config/profiles/default/devcontainer/`. A project may also ship its own
`.devcontainer/`, which overrides both. This is the committed source for the
template the spec stages at `/srv/stacks/devcontainers/templates/openclaw-default/`
(tz §16).

## Public-repo rules applied here
This file lives in the **public** repo, so it is generic and English, with **no
secrets, no host paths, no private naming**. It was derived from a proven
OpenClaw devcontainer and cleaned to those rules.

## What it contains
- `docker/dev.Dockerfile` — the dev image: OS toolchain only (Node + corepack +
  arch-scoped pnpm, Python venv, build/dev packages). Version pins mirror
  `profile.conf`.
- `.devcontainer/devcontainer.json` — builds that image, binds the workspace to
  `/workspace`, runs as `dev` (uid 1000), recommends the in-yard coding-agent
  extensions, and hardens the container (`cap-drop=ALL`, `no-new-privileges`).

## Deliberate omissions (don't "fix" these silently)
- **Project test tools are not baked.** Per `profile.conf`, `vitest`/
  `typescript`/`@types/node` and the Python tools come from the project's
  vendored deps (`pnpm --frozen-lockfile`, `pyproject`), so a bump has a single
  source of truth in the project repo. The image carries only the OS toolchain.
- **Agent state is the yard default, sourced from the yard — not the host.**
  Claude/Codex credentials + session/usage are staged on the host under
  `$HOST_BASE/host-agent/{claude,codex}`, mounted rw into the yard at
  `/mnt/host/agent` (the `host-agent` entry in `HOST_MOUNTS`, `config/subyard.env`
  — decision #23), and bound into this container from that yard path so
  subscription usage is one shared pool. No host paths are hardcoded here. The
  ssh-agent socket is forwarded into the yard by default (`FORWARD_SSH_AGENT=1`);
  see the commented line in `mounts` to use it from the container too. To opt out,
  remove the `host-agent` line from `HOST_MOUNTS` (and drop the two agent binds).
- **No project lifecycle hooks.** `initializeCommand`/`postCreateCommand` that
  reference a project's own scripts belong in that project's `.devcontainer/`,
  not in this default.
- **Caches are workspace-local.** The profile's shared `/srv/cache/*` caches are
  for `yard agent` machines; wire them in per project if you want cross-container
  sharing here.

## Optional heavy features
`browser_tests` and `sandbox_tests` are off by default. Enable them via
`OPTIONAL_FEATURES` in `profile.conf` and bake their system libs into a
project-specific image layer — see the notes in that profile.
