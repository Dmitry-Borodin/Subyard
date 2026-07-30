# Hermes Agent profile

The `hermes` profile installs a pinned, headless Hermes Agent in a dedicated
named yard. Hermes listens only on the yard's loopback interface. Remote access
uses the existing Subyard SSH path and a localhost-only forward; the profile
does not install Hermes Desktop, expose port 9119 on the owner host, or run the
Hermes gateway.

## Create and provision the yard

Choose an unused SSH port in the named-yard configuration:

```sh
mkdir -p ~/.config/subyard/yards/hermes
cat >~/.config/subyard/yards/hermes/config.env <<'EOF'
YARD_PROFILES=hermes
FORWARD_SSH_AGENT=0
SSH_PORT=2224
EOF

yard -Y hermes init
yard -Y hermes provision hermes
```

The profile installs Hermes Agent 0.19.0 from an exact source commit, uses a
pinned `uv` and Python, and resolves only the committed lock file. The
root-owned runtime is under `/opt/hermes-agent`; persistent state is under
`/srv/hermes`. Re-provisioning the same pin preserves state and the dashboard
session token.

Provisioning leaves `hermes-serve.service` disabled until a provider has been
configured and tested. Enter the yard, perform the provider's normal
interactive setup, run `hermes doctor`, and make one real inference. Record any
provider credential store outside `HERMES_HOME`; Hermes' native backup does not
promise to include arbitrary CLI or OS credential stores. After that check:

```sh
sudo hermes-provider-ready --inference-ok
systemctl is-active hermes-serve.service
ss -ltnp | grep '127.0.0.1:9119'
```

The approval marker is bound to the installed commit. A restore or pin change
invalidates it.

## Connect Hermes Desktop

On the client machine, register the remote owner host using its existing SSH
alias:

```sh
yard remote add hermes OWNER_SSH_ALIAS --yard hermes
ssh -NT \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -L 127.0.0.1:19119:127.0.0.1:9119 \
  yard-hermes
```

Set the official Hermes Desktop Remote URL to
`http://127.0.0.1:19119`. Transfer the value from
`/srv/hermes/.serve.env` through a separate secure operator channel and enter
it as the remote session token. Do not paste the token into shell arguments,
configuration repositories, task files, or logs. Closing the foreground SSH
process closes remote access.

## Encrypted backups

Hermes disaster-recovery backups are stopped-service full backups. The
profile-owned owner-host helper validates the archive twice and commits the ZIP
and metadata to an already initialized, encrypted restic repository:

```sh
runtime_root="$(cd "$(dirname "$(readlink -f "$(command -v yard)")")/.." && pwd)"
sudo "$runtime_root/config/profiles/hermes/backup-to-restic.sh" \
  --yard hermes \
  --restic-env /root/.config/subyard/hermes-restic.env \
  --type scheduled
```

The selected environment file must be root-owned, non-symlinked, and mode
`0600` or stricter. It supplies normal `RESTIC_REPOSITORY` and password-source
variables. Keep the repository outside the yard's removable storage,
preferably off-host. The helper reports a verified snapshot ID and applies
retention of 7 daily, 4 weekly, and 6 monthly snapshots for that yard. Schedule
regular `restic check` separately.

Create a `pre-update` backup before changing the pin and a `pre-teardown`
backup before destructive teardown. Provision refuses a commit change without
a verified backup marker for the currently installed commit.

For a restore, provision a clean yard with the same exact profile commit, copy
the verified ZIP into that yard, then run:

```sh
sudo hermes-restore /path/to/hermes-backup.zip EXPECTED_SHA256
```

The restore leaves the service disabled and removes provider approval. Recheck
external credentials, run `hermes doctor`, make a real inference, and approve
the provider again. Do not use cross-version import as rollback: restore the
old runtime pin and its matching backup together.

## Maintainer acceptance

The disposable-host acceptance creates two isolated named yards, verifies
loopback REST/WebSocket authentication and SSH tunnel closure/reconnect, writes
representative persistent state, commits a stopped-service backup to an
encrypted restic repository, and restores it into the second clean yard:

```sh
dev/agent-e2e.sh --purpose hermes-profile --vm 1 -- \
  ./dev/e2e/hermes-profile.sh
```

That default lane uses a provider fixture. A release candidate must also pass
the secure maintainer lane with `HERMES_E2E_REQUIRE_CODEX=1`: stage the
maintainer's Codex auth only inside the same disposable lease and outside the
filtered worktree archive, never as an argument or environment value and never
in tracked files or logs. The lane performs a real terminal-tool inference
both before backup and after clean restore.
