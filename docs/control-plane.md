# Control-plane architecture

Subyard's production control plane is Bash, with explicit module boundaries that are also the
compatibility contracts for a future engine implementation. There is one implementation path for
each operation: registries select a handler, the handler loads one validated context, and side
effects stay behind stage, transport, state, credential, or profile-resource adapters.

## Implementation map

```text
bin/yard
  ├── config/commands.registry          command/help/completion/remote-plane metadata
  ├── scripts/lib/                      context, config, registry, UI, cache, host adapters
  ├── scripts/state/                    project store, resolver, transport, yard metadata
  ├── scripts/reconcile/
  │     └── stages/                     one check/plan/apply/verify contract per init stage
  ├── scripts/credentials/              DAG policy and explicit crypto/store/peer adapters
  └── config/profiles/<profile>/
        ├── provision.sh                optional in-yard toolchain
        └── resources/<resource>/       profile-owned lifecycle mechanics
```

`bin/yard` owns bootstrap, global yard selection, audit, remote-plane selection, and dispatch. It
does not own command-specific or profile-specific lifecycle logic. `scripts/init.sh` composes the
ordered stage planner and owns the one top-level confirmation plus the separate desired-power
finalization transaction.

## Recorded P0 baseline

The pre-consolidation baseline on 2026-07-20 was:

| Surface | Baseline |
|---|---:|
| Production shell entrypoints/hooks | 56 files / 12,272 lines |
| Host-free tests | 29 files / 3,159 lines |
| Entrypoints sourcing the ambient `lib.sh` | 40 |
| `lib.sh` | 519 lines |
| `lib-state.sh` | 593 lines |
| `lib-keys.sh` | 1,066 lines |
| `init.sh` | 602 lines |

The compatibility baseline includes top-level help/list, command aliases, exit status propagation,
global yard selection, local/named/remote routing, config precedence, prompts, qualified project
selectors, owner registry convergence, credential redaction/conflicts, init re-probe/verify, and
deferred power finalization. The host-free tests characterize those behaviors before real host
acceptance.

## Stable interfaces

### Commands

`config/commands.registry` is pipe-delimited:

```text
name|aliases|handler|arg0|remote|visibility|section|completion|display|summary|options|verbs
```

- `remote` is `local`, `forward`, or `deny`.
- `handler` is a script under `scripts/`, or a reserved dispatcher adapter such as `@help`.
- `completion` names a provider consumed by both Bash and Zsh completion; `options` and `verbs`
  carry their shared token lists.
- Public dispatch, aliases, `yard --list`, top-level help, and completion metadata all use this
  registry. `yard --command-manifest` exposes the validated machine-readable rows.

Profile resource commands use the separate `.res` interface below because profiles own those
commands and mechanics.

### Config and context

Every executable explicitly composes source-only modules and calls `subyard_context_load` once.
Loading selects the local/named/remote yard, applies generic default config, normalizes paths, and
validates the complete context before side effects. It then exposes the non-secret normalized values
through the read-only `context_value` snapshot. A second load is a no-op.

The validated context contract includes:

- `YARD_TYPE=local|remote` and `INSTANCE_TYPE=container|vm`;
- a valid local `SSH_PORT`, or `REMOTE_DEST` for a remote yard;
- absolute normalized runtime paths;
- `HOST_BASE == RESTRICTED_DISK_PATHS`, never a broad host root;
- validated UID, shift mode, sudo, and SSH-agent policy values.

Source-only domain modules do not load configuration themselves.

### Project state and routing

Project state is one owner-only JSON file per project ID. Schema 1 requires typed identity, name,
host/yard paths, mode, and SSH host; target/profile and yard-origin markers are optional compatible
fields. Reads reject corrupt JSON, filename/identity mismatch, invalid targets, and unknown schema
versions. Writes use a mode-0600 candidate in the same directory, validate it, then atomically
rename it over the prior record.

The modules are intentionally separate:

- `state/store.sh`: schema, atomic records, owner-local path preservation;
- `state/resolver.sh`: in-yard and qualified cross-yard selection;
- `state/transport.sh`: remote owner control plane and direct yard data-plane probes;
- `state/metadata.sh`: yard discovery, synthetic backfill, and owner convergence;
- `lib/cache.sh`: last-good remote `_info` cache.

Owner upsert/unregister, second-controller discovery, qualified selectors, and synthetic `--live`
records are compatibility behavior, not best-effort implementation details.

### Reconciliation stages

The ordered registry contains one descriptor per stage:

```text
stage-id|stage_function_prefix
```

Each module under `scripts/reconcile/stages/` must implement `<prefix>_check`, `_plan`, `_apply`, and
`_verify`. The planner validates the registry, re-checks immediately before apply, verifies
immediately after apply, and stops on failure. A rerun skips converged stages and resumes from live
state; no completion marker replaces the probes. Desired-power finalization is a separate verified
transaction after optional profile provisioning.

### Credential ledger

The host-scoped ledger is physically outside the checkout and every managed yard mount. Its shared
Git store contains signed SOPS/age ciphertext; local-only records and identity keys never enter that
store.

`credentials/domain.sh` accepts explicit repository/credential/JSON inputs and calls injected record,
decrypt, and publish ports. It contains no concrete SOPS, Git, SSH, or `KEYS_*` config dependency.
Production adapters separately own protected store I/O, crypto/signatures, revision publication,
consumer materialization, peer transport/trust, retry state, verification/quarantine, and sync.
Secret payload enters only through protected stdin or a mode-0400/0600 file and is never placed in
command arguments, environment metadata, audit output, or a revision's unencrypted fields.

The public revision shape remains `config/keys/revision.schema.json`. Revision DAG, recipient
intersection, revoke/tombstone behavior, assignment epoch, append-only verification, quarantine,
local-only isolation, and fail-closed exclusive handoff are conformance contracts.

### Profile resources

A resource descriptor is `config/profiles/<profile>/resources/<name>.res` with:

```text
COMMAND=<yard-command>
HANDLER=resources/<name>/handler.sh
TITLE="..."
VERBS="..."
BRINGUP=<verb>
SHUTDOWN=<verb>
```

`HANDLER` is relative to the owning profile. Registry validation rejects path traversal, duplicate
names/commands, collisions with core commands, invalid verbs, and missing executables. The handler
owns every lifecycle verb including the silent `is-up` probe. Core code may only discover, dispatch,
probe, and render hints from the descriptor.

## Test topology

`./tests/run.sh` syntax-checks every nested shell file, validates that each top-level test belongs to
exactly one suite, then runs:

- `tests/suites/unit.list`: pure and filesystem-local policy;
- `tests/suites/contract.list`: CLI, context, registry, convergence, and security contracts;
- `tests/suites/integration.list`: process tests with temporary roots and fake external commands.

CI runs the same suite and recursively ShellChecks all Bash entrypoints, modules, profile handlers,
and tests. Synthetic credential fixtures contain no real secret.

## Real-host acceptance lane

Host-free fakes cannot prove Incus, kernel, network, mount, systemd, or real SSH behavior. Before a
release that changes these boundaries, run the following on dedicated `e2e-*` contexts only:

1. For both a container and VM context: `yard -Y <context> init`, rerun it as a no-op, introduce one
   safe managed drift (for example the ccusage convergence marker), rerun to repair it, then reboot
   and confirm desired power.
2. Sync a synthetic repository, verify `list`, `shell`, `export`, `remove`, and an optional L2
   `up → info → down` cycle. Exercise each active profile resource's bring-up/status/shutdown path.
3. From a second controller, run `list --live` and confirm synthetic discovery without importing the
   first controller's host path.
4. Register a dedicated remote owner, verify owner lifecycle forwarding and direct
   `sync → list → export → remove`, rotate only a test host key, and confirm an unreachable owner
   produces the documented diagnostic/cache behavior.
5. On two dedicated owner hosts, run `keys trust → add synthetic shared/exclusive records → sync →
   concurrent compatible and incompatible heads → resolve → exclusive move`; verify pinned tools,
   the persistent timer, SSH transport, consumer permissions, redaction, and payload absence from
   argv/env/log/diff.
6. Tear down only the dedicated `e2e-*` yards and confirm host networking remains available.

Capture results outside the public repository and never include credentials or private host names.

## Adding a command, stage, or resource

- Command: add one validated registry row, implement the handler, select a completion provider, and
  extend a contract/integration test. Do not edit dispatch/help lists separately.
- Stage: add one stage module with all four methods and one registry descriptor; add no-op, drift,
  failed-verify, and resume coverage.
- Profile resource: keep mechanics below its profile, add a `.res` descriptor and executable
  handler, implement silent `is-up`, and test at least probe plus reverse lifecycle behavior.

Run `./tests/run.sh`, the recursive ShellCheck command used by CI, and `git diff --check` before
submitting changes.
