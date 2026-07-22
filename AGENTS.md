# Subyard — agent instructions

This is the **public** repository. Keep everything here generic and in English; no private
data. Project background, specs, and planning live in a separate private repo.

## Private overlay
If `private/AGENTS.md` exists locally (it is gitignored and lives in the separate private repo),
read and follow it **in addition** to this file. It carries private, non-public working rules

## Validation

Run `make build` to compile the development binary at `.build/yard`; `go.mod` selects the Go
toolchain. Run `./tests/run.sh` before finishing shell or CLI changes. CI additionally runs
`shellcheck -x -S warning` over the CLI, scripts, provision hooks, tests, and Bash completion.

## Agent E2E workflow

The operator owns `start`, `test-vms up/down` and `stop`. Agents use only allocated VMs.

Before first use, run `dev/agent-e2e.sh --prepare`, then ask the operator to run
`yard -Y e2e-yard init`. The private key stays under `~/.subyard/e2e/`; only its public half is
written to ignored `temp/agent-e2e/e2e-yard/agent-access.pub`.

Run checks from the current public worktree with:

```sh
dev/agent-e2e.sh -- ./bin/yard --version
dev/agent-e2e.sh --vm 1 -- ./tests/some-real-host-check.sh
```

The runner filters private/ignored files, verifies the bundle and removes its guest worktree.
Use `--ssh 1|2` for diagnostics and `--ssh-config` for direct OpenSSH. Run `--verify-boundary`
after transport or enrollment changes. Never use the privileged outer yard as an agent workspace.
Run `dev/e2e/p0-acceptance.sh` for the full allocated two-VM matrix.

VM1 must test legacy convergence before current `yard init`:

```sh
SUBYARD_E2E_LEGACY_FIXTURE=1 \
  dev/e2e/seed-test-vms-legacy-state.sh <project> <instance>
```

The fixture is restricted to disposable VM1 candidate yards.
