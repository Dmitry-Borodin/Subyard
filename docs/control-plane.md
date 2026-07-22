# Control-plane architecture

Subyard's production entrypoint and control plane are a native Go engine. Bash is limited to narrow
physical adapters for platform mutations and protected payloads. There is one implementation path
for each operation: Go owns the workflow and validated context; side effects stay behind explicit
ports.

## Implementation map

```text
bin/yard                                source-tree and release-runtime launcher
.build/yard                             ignored source-development engine
<runtime>/current/bin/yard-engine       verified amd64/arm64 production engine
cmd/yard                                native CLI/RPC entrypoint
internal/
  ├── command, config, domain           manifest and immutable context
  ├── application, credential           routing/events and credential DAG policy
  ├── state, migration, rpc              atomic state, schema checks and framed sessions
  └── adapters/                          Incus, metadata, shell and local/SSH transports
scripts/
  ├── lib/                              shared platform adapter contracts
  ├── reconcile/
  │     └── stages/                     one check/plan/apply/verify contract per init stage
  └── credentials/                      protected crypto/store/peer/materialization adapters
config/profiles/<profile>/
  ├── provision.sh                      optional in-yard toolchain
  └── resources/<resource>/             profile-owned lifecycle mechanics
```

The Go engine owns global yard selection, validated config, operation identity/audit, remote-plane
selection, project state/resolution, read-only status/inventory, credential DAG decisions, official
Incus calls and the versioned stdio RPC. The source launcher executes only an explicit `.build/yard`
development candidate. Installed commands use an immutable, checksum/provenance-verified runtime
containing its launcher, engine, scripts, registry and completion files; `current`/`previous` switch
the whole runtime and production never reads a source checkout. Non-interactive mutations share the
Go-owned plan, consequences, confirmation, operation ID, audit, events and cancellation path across
CLI and RPC. Go owns reconciliation order, retries and transactions. A shell leaf may probe or
mutate one physical boundary; it does not select stages, route operations or make policy decisions.
The current init and credential shell workflows are migration debt.

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
name|aliases|handler|arg0|remote|effect|visibility|section|completion|display|summary|options|verbs
```

- `remote` is `local`, `forward`, or `deny`.
- `effect` is conservatively `read` or `mutate`; a mixed command is `mutate`.
- `handler` is a script under `scripts/`, or a reserved dispatcher adapter such as `@help`/`@rpc`.
- `completion` names a provider consumed by both Bash and Zsh completion; `options` and `verbs`
  carry their shared token lists.
- Public dispatch, aliases, `yard --list`, top-level help, and completion metadata all use this
  registry. `yard --command-manifest` exposes the validated machine-readable rows.

Profile resource commands use the separate `.res` interface below because profiles own those
commands and mechanics.

### RPC

`yard rpc --stdio` is the only machine protocol. Each frame is a four-byte big-endian length
followed by at most 1 MiB of JSON. A session must call `rpc.negotiate` first; responses and ordered
events carry protocol version, request/operation ID and typed errors. A `cancel` frame targets an
active operation ID, and a bounded writer queue closes a client that cannot keep up.
Negotiation also returns the engine build version, supported protocol range and capabilities so a
rolling controller/owner-host mismatch is explicit. Calls may carry an RFC 3339 deadline; expiry and
explicit cancellation produce different typed errors.
The outer event `sequence` and `revision` are one monotonic per-session stream; adapter-local Incus
revisions remain typed event data and cannot make the RPC revision move backwards after a snapshot.

The switched surface exposes `command.list`, `context.get`, `operation.route`, `operation.plan`,
`operation.execute`, `project.list`, `yard.status`, `credential.list`, `credential.status`,
`incus.events`, `system.snapshot`, `system.resync` and `system.ping`. `operation.plan` accepts every
non-interactive mutating command backed by the structured adapter allowlist. Interactive terminal and
protected credential-payload commands keep their dedicated transport rather than treating human
stdin/stdout as a typed result. Its server-side plan is bounded and single-use; execution requires an
explicit `confirmed=true` and emits correlated start/final events. The full
snapshot contains one revision over context, public commands, project inventory, yard status and
redacted credential metadata; `snapshot.ready` and Incus events use the same ordered event channel.
Human CLI output is never parsed as a fallback API. Secret-like fields are rejected recursively from
RPC parameters, Incus event metadata is allowlisted, and stdout contains frames only.

### Config and context

The Go engine parses assignment-only config without executing shell, selects the local/named/remote
yard, applies generic defaults, normalizes paths and validates the complete context before dispatch.
It passes the validated environment to shell adapters with `SUBYARD_CONFIG_LOADED=1`; their existing
boundary captures the immutable non-secret view without sourcing the files again. Direct execution
of a system-adapter script retains the compatibility loader for diagnostics.

The validated context contract includes:

- `YARD_TYPE=local|remote` and `INSTANCE_TYPE=container|vm`;
- a valid local `SSH_PORT`, or `REMOTE_DEST` for a remote yard;
- absolute normalized runtime paths;
- `HOST_BASE == RESTRICTED_DISK_PATHS`, never a broad host root;
- validated UID, shift mode, sudo, and SSH-agent policy values.

Source-only domain modules do not load configuration themselves.

Structured system adapters are selected from the validated command manifest and receive only declared
non-secret context keys. Metadata uses a dedicated file descriptor and protected input uses stdin.
Leaf commands report diagnostics normally; the runner converts their exit status into a typed result.
The runner supplies a fixed `PATH`, enforces output/time limits and terminates the process group on
cancellation.

### Project state and routing

The native `internal/state` store is the only project-state implementation. Project state is one
owner-only JSON file per project ID. Schema 1 requires typed identity, name,
host/yard paths, mode, and SSH host; target/profile and yard-origin markers are optional compatible
fields. Reads reject corrupt JSON, filename/identity mismatch, invalid targets, and unknown schema
versions. Writes use a mode-0600 candidate in the same directory, validate it, then atomically
rename it over the prior record. When a store is opened, valid owner-owned schema-1 records whose
mode matches the original Bash writer's `0666 & umask` output are tightened in place to `0600`
through a no-follow file descriptor; symlinks, malformed records and anomalous modes remain
fail-closed. The same repair is registered in `_migrate apply` for release upgrades.

Before a project adapter starts, Go resolves paths/names/qualified selectors across yards, loads the
owning context, validates the typed record and supplies a `SUBYARD_PROJECT_*` snapshot. Physical
project adapters require that snapshot; they do not reload config, parse selectors or open state.
Operation options such as remove mode and image rebuild are passed as validated fields.
After a successful mutating adapter, Go atomically publishes or deletes controller state and, for a
remote yard, converges the owner endpoint before publishing controller state.

Shell project leaves may execute prepared SSH, Incus, tar or Docker operations. They do not probe the
owner control plane, classify reachability, reload registry state or decide routes. The retired
`state/store.sh`, `state/resolver.sh` and `state/transport.sh` shims must not return.
Native project actions use `@project`; `clone`, `sync`, `bind` and `remove` have no shell handlers.

Remote registration, trust repair, removal and listing are native. Preparation probes the trusted
owner and scans the yard key without local mutation; old and new fingerprints enter the operation
plan before confirmation. Apply consumes that prepared evidence and atomically rolls back local
context, SSH config, trust and cache files if the data-plane verification fails.

Project-environment profile validation, mount/device policy and lifecycle planning also belong to
Go. A remaining shell hook may only execute the prepared Incus or Docker operation.

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

Native credential policy validates the revision graph and owns heads, terminal precedence, metadata
compatibility, recipient intersection/rekey, peer trust merging, assignment epochs and freshness,
and retry scheduling. Its RPC view
projects only allowlisted metadata and never decodes encrypted payload or SOPS fields. Protected
adapters own only store I/O, cryptographic operations, consumer materialization and peer transport.
They consume a Go-prepared decision and do not coordinate the workflow. The current shell credential
coordinator is migration debt.
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

`./tests/run.sh` verifies gofmt, vet, race tests, a fuzz smoke and a static build; syntax-checks every
nested shell file; validates that each top-level test belongs to exactly one suite; then runs:

- `tests/suites/unit.list`: pure and filesystem-local policy;
- `tests/suites/contract.list`: CLI, context, registry, convergence, and security contracts;
- `tests/suites/integration.list`: process tests with temporary roots and fake external commands.

CI selects Go from `go.mod`, runs the same suite and recursively ShellChecks all Bash entrypoints,
modules, profile handlers and tests. The fake Incus Unix server implements official-client REST,
async-operation WebSockets, errors, cancellation and event disconnects. Synthetic credential fixtures
contain no real secret. The opt-in E2E VM subset is documented in
[`real-host-acceptance.md`](real-host-acceptance.md).

## E2E VM acceptance lane

Host-free fakes cannot prove Incus, kernel, network, mount, systemd, or real SSH behavior. The
operator allocates two disposable E2E VMs; the agent runs `dev/e2e/p0-acceptance.sh` without changing
their lifecycle. Do not run this lane on the operator host or in the privileged outer yard.

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
5. On the two E2E VMs, run `keys trust → add synthetic shared/exclusive records → sync →
   concurrent compatible and incompatible heads → resolve → exclusive move`; verify pinned tools,
   the persistent timer, SSH transport, consumer permissions, redaction, and payload absence from
   argv/env/log/diff.
6. Remove candidate resources and worktrees; allocation teardown remains an operator action.

Capture results outside the public repository and never include credentials or private host names.

## Adding a command, stage, or resource

- Command: add one validated registry row and a Go use case. Add Shell only for a physical leaf, then
  extend a contract/integration test. Do not add another dispatch list.
- Stage: add one stage module with all four methods and one registry descriptor; add no-op, drift,
  failed-verify, and resume coverage.
- Profile resource: keep mechanics below its profile, add a `.res` descriptor and executable
  handler, implement silent `is-up`, and test at least probe plus reverse lifecycle behavior.

Run `./tests/run.sh`, the recursive ShellCheck command used by CI, and `git diff --check` before
submitting changes.
