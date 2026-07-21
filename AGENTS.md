# Subyard — agent instructions

This is the **public** repository. Keep everything here generic and in English; no private
data. Project background, specs, and planning live in a separate private repo.

## Private overlay
If `private/AGENTS.md` exists locally (it is gitignored and lives in the separate private repo),
read and follow it **in addition** to this file. It carries private, non-public working rules

## Validation

Run `./tests/run.sh` before finishing shell or CLI changes. CI additionally runs
`shellcheck -x -S warning` over the CLI, scripts, provision hooks, tests, and Bash completion.

## Agent E2E workflow

The operator owns only lab allocation: `yard -Y e2e-yard test-vms up` before agent work and
`test-vms down`/`stop` after it. An agent must not run those lifecycle commands.

Once both VMs are allocated, use `scripts/agent-e2e.sh` from the current public worktree. It copies
tracked, dirty and non-ignored untracked files to one or both VMs, executes an arbitrary command,
and removes its remote worktree on every exit:

```sh
scripts/agent-e2e.sh -- ./bin/yard --version
scripts/agent-e2e.sh --vm 1 -- ./tests/some-real-host-check.sh
```

Run independent checks on either VM and cross-owner checks after both are prepared. The script must
remain allocation-neutral: it may use `status`/`exec`, but never `up`, `down`, `start` or `stop`.
Do not bypass its public-worktree filter or copy `.git`, `private/`, ignored credentials or live
machine configuration into the lab.
