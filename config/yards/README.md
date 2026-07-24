# Named yards

Create an installed yard at:

```text
~/.config/subyard/yards/<name>/config.env
```

Source checkouts may still use `private/yards/<name>.env`; release installation migrates it to
the installed path. Start from [`example.env`](example.env). `SSH_PORT` must be unique; the yard
name derives the instance, Incus project, SSH alias, storage volume and host-data root.

```sh
yard -Y openclaw init
yard @openclaw status
yard yards
```

Precedence is:

```text
runtime defaults
  -> overrides/shared
  -> config.env + overrides/host
  -> yards/<name>/config.env + yard overrides
  -> command environment
```

Public profiles remain in the immutable runtime. Set `YARD_TEMPLATE=<profile>` for a reusable yard
template or `YARD_PROFILES="<profile> ..."` to limit project profiles. Run `yard config paths` to
inspect effective sources, and `yard config status --all-local` / `yard config apply --all-local`
to verify or apply agent files to local yards. Remote yards are excluded from `--all-local`.

`yard teardown` removes only the selected yard and preserves the host credential ledger. Managed
mounts stay under that yard's `HOST_BASE`; `yard bind` is the explicit exception.

For the disposable two-VM profile:

```sh
YARD_TEMPLATE=test-vms
SSH_PORT=2223
```

See [`docs/test-vms.md`](../../docs/test-vms.md) and [`docs/keys.md`](../../docs/keys.md).
