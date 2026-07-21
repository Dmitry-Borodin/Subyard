# Named yards

Run several independent yards on one host, each with its own Incus instance, `/srv`, ssh
port, personal-data mount root and projects — while the default (unnamed) yard keeps working
exactly as before. Pick a yard for a command with `-Y <name>` / `--yard <name>`, or the
first-token sugar `@<name>`:

```
yard -Y openclaw init
yard @openclaw status
yard yards                 # table of every yard on this host
```

## Defining a yard

A yard is one env file, named after the yard. Drop it in a **registry** location (first match
wins):

| Location | Use |
| --- | --- |
| `private/yards/<name>.env` | operator overlay (private repo); wins over machine-local |
| `~/.config/subyard/yards/<name>.env` | machine-local, no private repo needed |

`config/yards/` (this directory) is **not** a registry — files here are dormant templates. Use
[`example.env`](example.env) for an ordinary named yard, or
[`e2e-yard.env.example`](e2e-yard.env.example) for the trusted two-VM acceptance yard. Copy the
chosen template to one of the registry paths above and rename it to the yard you want.

The only value you must set is `SSH_PORT` (a unique host loopback port — the one thing Subyard
cannot derive without risking a collision). Everything else is derived from the yard name and
overridable:

| Derived | Default for yard `<name>` |
| --- | --- |
| `INSTANCE_NAME` | `yard-<name>` |
| `INCUS_PROJECT` | `subyard-<name>` |
| `SSH_HOST` (ssh alias) | `yard-<name>` |
| `SRV_VOLUME` | `yard-srv-<name>` |
| `RESTRICTED_DISK_PATHS` ⇒ `HOST_BASE` | `/srv/subyard-<name>` |
| project state dir | `~/.config/subyard/yards/<name>/projects/` |

The default yard keeps the historical unnamed values (`yard`, `subyard`, `/srv/subyard`,
`~/.config/subyard/projects/`), so existing setups are untouched.

**Precedence.** Per-yard files beat `private/config.env`: config is layered as env override >
yard context > `private/config.env` > shipped defaults. Put machine-wide **globals** in
`private/config.env` (or `config/*.env`), and anything that must differ **per yard** — above all
`SSH_PORT` — in `yards/<name>.env`. A global `SSH_PORT` in `private/config.env` applies only to
yards that do not set their own; it can never collapse every named yard onto one port.

## Personal-data isolation

Each yard has its own managed `HOST_BASE` (`/srv/subyard-<name>`). Incus cannot combine its
disk-source allowlist with Subyard's idmapped mounts, so the CLI verifies managed `host-*`/`yx-*`
sources under that root and `yard security` audits the expanded live device set. An explicit
`yard bind <path>` may come from anywhere on the host: it warns that encapsulation is reduced, but
does not impose a project-root allowlist.

## Per-yard profiles

Set `YARD_PROFILES="<profile> …"` in a yard's env to scope it to specific profiles. `yard
provision` (no argument) then provisions exactly those, and `yard status` lists only their
shared resources. Unset = all profiles (the default-yard behavior).

## Lifecycle

Every lifecycle command takes the context: `yard -Y <name> {init,start,stop,status,provision,
logs,teardown,…}`. `yard -Y <name> teardown` removes only that yard's instance, project,
volume, ssh snippet and state — never another yard's. Shared host objects (the storage pool,
bridge, NetworkManager guard) are only removed when the last yard goes away.

The dedicated nested-VM acceptance yard has the conventional name `e2e-yard`. Define it in
`private/yards/e2e-yard.env` or `~/.config/subyard/yards/e2e-yard.env` by copying
[`e2e-yard.env.example`](e2e-yard.env.example), then initialize it with `yard -Y e2e-yard init`.
Its topology, trust boundary and lifecycle are documented in
[`docs/test-vms.md`](../../docs/test-vms.md).

## Encrypted credential exchange

Yard registration and project sync are credential-free. To share selected static credentials,
initialize the ledger normally on each physical owner host and explicitly enroll the peer:

```bash
yard -Y openclaw init
yard -Y srv1 init
yard -Y openclaw keys trust @srv1
```

Trust displays the age recipient and signing fingerprints and asks for confirmation. One command
installs reciprocal cryptographic trust. The side with the known route becomes the automatic `active`
initiator; the other side is `passive`/respond-only until it separately learns a reverse route.
Enrolled peers exchange only signed, recipient-authorized ciphertext. All local yard contexts share
one host identity/store; yard names remain consumer and exclusive-assignment targets. The store survives
yard teardown. See
[the credential-ledger contract](../../docs/keys.md).
