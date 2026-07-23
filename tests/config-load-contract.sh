#!/usr/bin/env bash
# Config selects one yard, normalizes/validates it once, and preserves layer precedence.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP/shipped/yards/profiles" "$TMP/config-home/yards" "$TMP/operator" "$TMP/host"
cat > "$TMP/shipped/incus.project.env" <<'ENV'
: "${INCUS_PROJECT:=subyard}"
ENV
cat > "$TMP/shipped/subyard.env" <<'ENV'
: "${INSTANCE_NAME:=yard}"
: "${INSTANCE_TYPE:=container}"
: "${SHIFT_MODE:=shift}"
: "${FORWARD_SSH_AGENT:=0}"
: "${DEV_SUDO:=0}"
: "${DEV_UID:=1000}"
ENV
cat > "$TMP/shipped/host.env" <<'ENV'
: "${SUBYARD_OPERATOR_HOME:?}"
: "${SUBYARD_CONFIG_HOME:?}"
: "${SUBYARD_HOME:?}"
: "${STORAGE_PATH:?}"
: "${HOST_BASE:?}"
: "${RESTRICTED_DISK_PATHS:?}"
ENV
: > "$TMP/shipped/agents.env"
: > "$TMP/shipped/ports.env"
cat > "$TMP/shipped/yards/profiles/test-vms.env" <<'ENV'
NESTED_E2E_VMS=1
E2E_VM_DISK=10GiB
ENV
cat > "$TMP/config-home/yards/named.env" <<ENV
SSH_PORT=3333
INSTANCE_NAME=fixture-yard
HOST_BASE=$TMP/host/../host
RESTRICTED_DISK_PATHS=$TMP/host
ENV

export SUBYARD_CONFIG_DIR="$TMP/shipped"
export SUBYARD_OPERATOR_HOME="$TMP/operator"
export SUBYARD_CONFIG_HOME="$TMP/config-home"
export SUBYARD_HOME="$TMP/data"
export STORAGE_PATH="$TMP/data/storage"
export SUBYARD_YARD=named

# shellcheck source=scripts/lib/runtime.sh
. "$ROOT/scripts/lib/runtime.sh"
# shellcheck source=scripts/lib/env.sh
. "$ROOT/scripts/lib/env.sh"
# shellcheck source=scripts/lib/registry.sh
. "$ROOT/scripts/lib/registry.sh"
# shellcheck source=scripts/lib/context.sh
. "$ROOT/scripts/lib/context.sh"
# shellcheck source=scripts/lib/ui.sh
. "$ROOT/scripts/lib/ui.sh"
# shellcheck source=scripts/lib/config.sh
. "$ROOT/scripts/lib/config.sh"

if [ ! -r "$ROOT/config/yards/profiles/test-vms.env" ]; then
  fail 'canonical test-vms profile is not shipped'
fi
if [ -e "$ROOT/config/yards/profiles/e2e-vms.env" ] \
  || [ -e "$TMP/shipped/yards/profiles/e2e-vms.env" ]; then
  fail 'retired e2e-vms profile is still shipped as an alias'
fi
if yard_env_file test-yard >/dev/null 2>&1 || yard_registry_names | grep -Fxq test-yard; then
  fail 'dormant public VM profile was registered without a machine activation'
fi

cat > "$TMP/config-home/yards/legacy-yard.env" <<'ENV'
YARD_TEMPLATE=e2e-vms
SSH_PORT=4333
ENV
set +e
retired_diagnostic="$(
  unset YARD_TEMPLATE SSH_PORT NESTED_E2E_VMS E2E_VM_DISK
  yard_source_env legacy-yard 2>&1
  printf 'retired template unexpectedly loaded\n'
  exit 91
)"
retired_rc=$?
set -e
[ "$retired_rc" -ne 0 ] && [ "$retired_rc" -ne 91 ] \
  || fail 'retired e2e-vms registration did not fail closed'
for expected in \
  "$TMP/config-home/yards/legacy-yard.env" \
  'YARD_TEMPLATE=test-vms' \
  'yard -Y legacy-yard check' \
  'yard -Y legacy-yard status' \
  'yard -Y legacy-yard test-vms status' \
  'yard -Y legacy-yard test-vms down' \
  'yard -Y legacy-yard teardown'; do
  printf '%s\n' "$retired_diagnostic" | grep -Fq "$expected" \
    || fail "retired-template diagnostic omitted: $expected"
done

cat > "$TMP/config-home/yards/test-yard.env" <<'ENV'
YARD_TEMPLATE=test-vms
SSH_PORT=4444
ENV
cat > "$TMP/config-home/yards/e2e-yard.env" <<'ENV'
YARD_TEMPLATE=test-vms
SSH_PORT=5555
ENV
[ "$(yard_env_file test-yard)" = "$TMP/config-home/yards/test-yard.env" ] \
  || fail 'machine-local test yard activation was not registered'
(
  unset SSH_PORT NESTED_E2E_VMS E2E_VM_DISK
  yard_source_env test-yard
  [ "$SSH_PORT" = 4444 ] && [ "$NESTED_E2E_VMS" = 1 ] && [ "$E2E_VM_DISK" = 10GiB ]
) || fail 'machine activation did not layer over the public VM profile'
yard_snapshot() (
  unset YARD_NAME INSTANCE_NAME INCUS_PROJECT SSH_HOST SRV_VOLUME RESTRICTED_DISK_PATHS
  unset SUBYARD_STATE_DIR SSH_PORT NESTED_E2E_VMS E2E_VM_DISK
  yard_source_env "$1"
  yard_apply_derivations "$1"
  printf '%s|%s|%s|%s|%s|%s\n' \
    "$INSTANCE_NAME" "$INCUS_PROJECT" "$SSH_HOST" "$SRV_VOLUME" "$SUBYARD_STATE_DIR" "$SSH_PORT"
)
test_yard_snapshot="$(yard_snapshot test-yard)"
old_yard_snapshot="$(yard_snapshot e2e-yard)"
[ "$test_yard_snapshot" = \
  "yard-test-yard|subyard-test-yard|yard-test-yard|yard-srv-test-yard|$TMP/config-home/yards/test-yard/projects|4444" ] \
  || fail "canonical test-yard derivations drifted: $test_yard_snapshot"
[ "$old_yard_snapshot" = \
  "yard-e2e-yard|subyard-e2e-yard|yard-e2e-yard|yard-srv-e2e-yard|$TMP/config-home/yards/e2e-yard/projects|5555" ] \
  || fail "migrated e2e-yard derivations drifted: $old_yard_snapshot"
[ "$test_yard_snapshot" != "$old_yard_snapshot" ] \
  || fail 'coexisting test-yard and migrated e2e-yard contexts collided'
(
  unset NESTED_E2E_VMS E2E_VM_DISK
  yard_source_env named
  [ -z "${NESTED_E2E_VMS:-}" ] && [ -z "${E2E_VM_DISK:-}" ]
) || fail 'public VM profile leaked into an ordinary named yard'
mkdir -p "$TMP/private/yards"
cat > "$TMP/private/yards/test-yard.env" <<'ENV'
YARD_TEMPLATE=test-vms
SSH_PORT=6666
ENV
(
  unset SSH_PORT NESTED_E2E_VMS
  yard_source_env test-yard
  [ "$SSH_PORT" = 6666 ] && [ "$NESTED_E2E_VMS" = 1 ]
) || fail 'private port override did not retain the selected public VM profile'
rm "$TMP/private/yards/test-yard.env"

subyard_context_load
[ "$INSTANCE_NAME" = fixture-yard ] || fail 'yard layer did not precede public defaults'
[ "$INCUS_PROJECT" = subyard-named ] || fail 'named-yard derivation was not applied'
[ "$SSH_PORT" = 3333 ] || fail 'named-yard port was not selected'
[ "$HOST_BASE" = "$TMP/host" ] || fail 'context path was not normalized'
[ "${SUBYARD_CONTEXT_READY:-}" = 1 ] || fail 'validated context was not marked ready'
[ "$(context_value sshPort)" = 3333 ] || fail 'immutable context snapshot lost the selected port'
if (SUBYARD_CONTEXT_VALUES[sshPort]=4444) 2>/dev/null; then
  fail 'validated context snapshot remained mutable'
fi

printf 'SSH_PORT=4444\n' >> "$TMP/config-home/yards/named.env"
subyard_context_load
[ "$SSH_PORT" = 3333 ] || fail 'context was loaded more than once'

printf 'ok: config/context selection is explicit, normalized and single-load\n'
