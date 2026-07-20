#!/usr/bin/env bash
# Config selects one yard, normalizes/validates it once, and preserves layer precedence.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP/shipped" "$TMP/config-home/yards" "$TMP/operator" "$TMP/host"
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
