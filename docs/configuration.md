# Subyard configuration

Subyard combines immutable settings shipped with its runtime, persistent local settings, and
temporary command overrides into one effective configuration. Use the CLI to inspect that result;
the files remain the source of truth.

```sh
yard config show
yard config show SSH_PORT
yard -Y demo config show
yard config paths
```

`config show` lists effective non-secret settings, their winning scope and source, and how they are
consumed. Passing one setting name shows every applicable layer as `effective`, `overridden`, or
`unset`. Secret inputs and unrelated environment variables are not settings and are never included.

## Storage roles

The default configuration root is `~/.config/subyard`. It contains several roles, not one monolithic
configuration:

| Path | Role |
|---|---|
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

Host-wide values go in `config.env`:

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
  -> host-wide scalar settings
  -> named-yard derivations and selected shipped profile
  -> named-yard scalar settings
  -> current command environment
```

The default yard omits the named-yard layers. A command environment value is temporary and has the
highest precedence. `yard [-Y <yard>] config show <SETTING>` is the authoritative explanation of the
actual chain, including derived values.

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
