# Subyard configuration

Subyard combines immutable settings shipped with its runtime, persistent local settings, and
temporary command overrides into one effective configuration. Use the CLI to inspect that result;
the files remain the source of truth.

```sh
yard config fields
yard config fields SSH_PORT
yard config show
yard config show SSH_PORT
yard -Y demo config show
yard config paths
```

`config fields` is the public typed field reference. It reports the shipped default, kind, type,
allowed scopes, syncability, merge mode, application mode and domain owner from the same catalog
used by the production resolver. `config show` lists effective non-secret settings, their winning
scope and source, and how they are consumed. Passing one setting name shows every applicable layer
as `effective`, `overridden`, or `unset`. Unknown fields, wrong scopes and invalid values fail
closed; secret inputs and unrelated environment variables are not settings.

## Storage roles

The default configuration root is `~/.config/subyard`. It contains several roles, not one monolithic
configuration:

| Path | Role |
|---|---|
| `overrides/shared/config.env` | Explicitly shareable scalar settings |
| `config.env` | Host-wide scalar settings |
| `overrides/shared/` | Explicitly shareable non-secret file settings |
| `overrides/host/` | File settings specific to this owner host |
| `yards/<name>/config.env` | Named-yard definition and scalar settings |
| `yards/<name>/overrides/` | File settings specific to one yard |
| `secrets/` | Secret inputs, not settings |
| `generated/` | Materialized consumers, not settings |
| `keys/` | Encrypted credential ledger and its state |
| `projects/` | Runtime project state |
| `tools/` | Subyard-managed support tools |

Run `yard config paths` to resolve these roles for the current installation and selected yard.
Immutable shipped defaults stay in the installed runtime and do not belong in the configuration root.

## Scalar settings

Common portable values may go in `overrides/shared/config.env` only when `config fields` lists the
`shared` scope. Host-wide values go in `config.env`:

```sh
DEV_SUDO=1
```

A named yard has its own settings:

```sh
# ~/.config/subyard/yards/demo/config.env
SSH_PORT=2223
YARD_TEMPLATE=test-vms
```

Scalar precedence is:

```text
shipped defaults
  -> explicitly shareable scalar settings
  -> host-wide scalar settings
  -> named-yard derivations and selected shipped profile
  -> named-yard scalar settings
  -> current command environment
```

The default yard omits the named-yard layers. A command environment value is temporary and has the
highest precedence. It is never persisted by config sync. `yard [-Y <yard>] config show <SETTING>`
is the authoritative explanation of the actual chain, including derived values. Start from
[`config/settings.env.example`](../config/settings.env.example).

## File settings

Known file settings, such as coding-agent configuration and rules, start with a shipped file and may
be replaced by the matching file under `overrides/shared`, `overrides/host`, or a named yard's
`overrides` directory. Their precedence is shipped, shared, host, yard, then a command override.

These directories currently override known file settings only. They are not generic scalar
configuration directories.

## Applying changes

Settings are resolved on every `yard` command. The `APPLIES` column in `yard config show` identifies
the consumer:

- `next command` means the resolver uses the new value on the next invocation;
- `yard init` means the value controls infrastructure or provisioning reconciled by `yard init`;
- `config apply` means a file setting can be refreshed in a running local yard with
  `yard config apply`.

`yard config status [--all-local]` checks only materialized file settings in running local yards.
`yard config apply [--all-local]` refreshes those consumers after confirmation. Neither command is a
generic scalar settings writer; edit the appropriate plain configuration file and confirm the result
with `config show`.

Remote yard definitions can be inspected with `yard -Y <remote> config show`. `--all-local` never
changes remote owner hosts implicitly.

## Versioned private configuration

Keep private desired settings in a separate clean Git checkout. Do not turn the entire
`$SUBYARD_CONFIG_HOME` into a checkout: it also contains project state, credential records, generated
consumers and support tools. `.gitignore`, a symlink farm or recursive `rsync --delete` is not an
ownership boundary.

Release installation and migration never ask for a Git URL or require network access. Connect the
private repository explicitly once on each physical owner host:

```sh
yard config source connect \
  git@github.com:you/subyard-config.git \
  --host-id workstation-a
```

`source connect` prepares the clone in a private temporary directory, validates its selected HostID
and exact adoption plan, then asks once before installing the checkout, registering its path and
applying that plan. The default destination is `~/.local/share/subyard-config`; use `--checkout` to
select an existing checkout or another destination. An existing checkout must have the requested
`origin`. A declined or invalid staged clone is removed.

Yard does not store Git credentials. Configure SSH or a Git credential helper on that owner host;
credential-bearing URLs, URL queries and fragments are rejected. `connect` performs only the initial
clone. Yard never commits or pushes, and it does not run later `git fetch` or `git pull` commands.

The checkout root contains a tracked `subyard-config.json`:

```json
{
  "schemaVersion": 1
}
```

Its fixed managed layout is:

```text
subyard-config.json
shared/
  config.env
  overrides/
    agents/...
hosts/
  <HostID>/
    config.env
    overrides/
      agents/...
    yards/
      <yard>/
        config.env
        overrides/
          agents/...
```

`config.env` under the selected host is required, even when empty. Scalar assignments must be
syncable in their exact shared, host or yard scope. Versioned file settings are regular,
non-executable files at catalog-known paths below `overrides/agents`; path assignments in
`config.env` are rejected. The source manifest schema is
[`config/subyard-config.schema.json`](../config/subyard-config.schema.json).

The first sync snapshots an owner-host ID. By default it uses the current hostname; set
`SUBYARD_HOST_ID=<safe-id>` for the first invocation to choose another value. The saved
`$SUBYARD_CONFIG_HOME/host-id` is local identity state, is never imported from Git and is not renamed
by later syncs. Each host selects only `shared` and `hosts/<HostID>`, so two hosts may have yards with
the same name without collapsing them.

After onboarding, use Git itself for transport and history. The registered path is available through
`config source path`, and `config sync` no longer needs the path argument:

```sh
git -C "$(yard config source path)" pull --ff-only
yard config sync --check
yard config sync
```

`--check` is read-only, never prompts, and exits non-zero when an apply or local manifest update is
needed. A changing sync prints the source commit and exact redacted managed-path plan, then asks once.
It does not run `init`, `start`, `stop`, `teardown`, `config apply`, project operations or Git
commands. Follow-up commands are printed by application mode.

An existing unmanaged target requires a reviewed first import with `--adopt`. Later local edits are
reported as managed drift and restored only through the confirmed exact plan. A path removed from Git
is deleted only when the local manifest owned its previous exact digest. Removing a yard definition
fails while its Incus yard or project state still exists; sync never becomes teardown.

The source must be an operator-owned Git worktree root with a clean selected subtree. Tracked,
untracked, ignored, unmerged, symlinked, hard-linked, executable or group/world-writable inputs fail
closed. `projects`, desired power, observed Incus state, SSH trust, secrets, keys, generated
consumers, exports, logs, storage and support tools are outside the source schema and local manifest.

To roll back desired settings, check out or revert the intended Git revision and run the same check
and sync commands. An interrupted confirmed transaction is recovered before the next mutating sync;
`--check` reports pending recovery without changing the live root.

When invoked for a registered remote yard, `config source connect`, `config source path` and
`config sync` run on that owner host:

```sh
yard -Y remote config source connect \
  git@github.com:you/subyard-config.git \
  --host-id remote-owner
yard -Y remote config sync --check
```

The checkout and Git authentication stay on the owner host; the controller does not upload or cache
the repository and there is no implicit all-host fan-out.

### Bootstrapping an existing host

First choose the stable owner-host ID that will name this host's subtree. Before creating files,
classify current values with `yard config fields` and inspect their provenance with
`yard config show`. Only fields marked `syncable: yes` may be copied:

- portable fields that explicitly allow `shared` go to `shared/config.env`;
- host-specific fields go to `hosts/<HostID>/config.env`;
- named-yard fields go to `hosts/<HostID>/yards/<yard>/config.env`;
- catalog-known agent config and rules files keep their relative path below the matching
  `overrides/agents` directory;
- secrets, keys, generated consumers, project state, host identity, desired power and support tools
  stay local and are never copied.

A minimal repository for the first host can be prepared without reading or copying the whole live
root:

```sh
checkout=$HOME/.local/share/subyard-config
host_id=replace-with-stable-host-id

install -d -m 0700 "$checkout/hosts/$host_id"
git -C "$checkout" init
printf '%s\n' '{"schemaVersion":1}' >"$checkout/subyard-config.json"
: >"$checkout/hosts/$host_id/config.env"
git -C "$checkout" add subyard-config.json "hosts/$host_id/config.env"
git -C "$checkout" commit -m 'Add Subyard configuration source'
git -C "$checkout" remote add origin git@github.com:you/subyard-config.git
git -C "$checkout" push -u origin HEAD
```

Move reviewed assignments and known override files into that layout and commit them. Connect the
existing checkout by giving the same origin URL and path; the command shows the exact adoption plan
and asks once:

```sh
yard config source connect \
  git@github.com:you/subyard-config.git \
  --host-id "$host_id" \
  --checkout "$checkout"
```

Do not copy `~/.config/subyard` recursively. In particular, do not add ignored secret or runtime
paths just to make the worktree appear clean: selected ignored and untracked source paths are
rejected. After `connect`, the checkout path and saved local `host-id` are authoritative. Each
additional owner host runs its own `source connect` against a HostID subtree already committed to
the repository.
