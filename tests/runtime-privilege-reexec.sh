#!/usr/bin/env bash
# Dispatcher identity is single-use, and sudo re-entry preserves operator-owned roots.
# shellcheck disable=SC2034 # fixture context variables are consumed indirectly by sourced host.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export SUBYARD_DISPATCH_PATH="$TMP/yard"
export SUBYARD_DISPATCH_COMMAND=init
export SUBYARD_DISPATCH_ARG0=init
set -- init --yes
# shellcheck source=scripts/lib/runtime.sh
. "$ROOT/scripts/lib/runtime.sh"

[ "$SUBYARD_SCRIPT_PATH" = "$TMP/yard" ] || fail 'top-level dispatcher path was not captured'
[ "${SUBYARD_SCRIPT_ARGV[*]}" = 'init --yes' ] || fail 'top-level dispatcher argv was not captured'
[ -z "${SUBYARD_DISPATCH_PATH+x}${SUBYARD_DISPATCH_COMMAND+x}${SUBYARD_DISPATCH_ARG0+x}" ] \
  || fail 'dispatcher identity remained inherited after capture'

nested_identity="$(RUNTIME="$ROOT/scripts/lib/runtime.sh" /bin/bash -c '
  set -euo pipefail
  . "$RUNTIME"
  printf "%s|%s\n" "$SUBYARD_SCRIPT_PATH" "${SUBYARD_SCRIPT_ARGV[*]}"
' "$TMP/phase.sh" --yes)"
[ "$nested_identity" = "$TMP/phase.sh|--yes" ] \
  || fail 'child phase inherited the top-level dispatcher identity'

install -d "$TMP/bin"
cat > "$TMP/bin/id" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -u) printf '1000\n' ;;
  -un) printf 'operator\n' ;;
  *) exec /usr/bin/id "$@" ;;
esac
SH
cat > "$TMP/bin/sudo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_SUDO_LOG"
SH
chmod +x "$TMP/bin/id" "$TMP/bin/sudo"

export MOCK_SUDO_LOG="$TMP/sudo.argv"
(
  PATH="$TMP/bin:$PATH"
  SUBYARD_USER=operator
  SUBYARD_OPERATOR_HOME="$TMP/operator home"
  SUBYARD_CONFIG_DIR="$TMP/repository/config"
  SUBYARD_CONFIG_HOME="$TMP/operator home/.config/subyard"
  SUBYARD_HOME="$TMP/operator home/.subyard"
  YARD_RUNTIME_ROOT="$TMP/operator home/.subyard/runtime"
  STORAGE_PATH="$TMP/operator home/.subyard/incus/storage"
  HOST_BASE="$TMP/host data"
  RESTRICTED_DISK_PATHS="$TMP/host data"
  SUBYARD_YARD=e2e-yard
  SUBYARD_YARD_EXPLICIT=1
  SUBYARD_SUDO_PREAUTHORIZED=1
  SUBYARD_POWER_ENGINE_SOURCE="$TMP/runtime/yard-engine"
  SUBYARD_ENGINE_CONTEXT=1
  SUBYARD_ENGINE_CONTEXT_SCHEMA=1
  YARD_TYPE=local
  INSTANCE_TYPE=container
  INSTANCE_NAME=yard-e2e
  INCUS_PROJECT=subyard-e2e
  INCUS_BRIDGE=incusbr0
  SSH_HOST=yard-e2e
  DEV_USER=dev
  DEV_UID=1000
  DEV_SUDO=0
  FORWARD_SSH_AGENT=0
  NESTED_E2E_VMS=1
  E2E_VM_IMAGE=images:debian/13/cloud
  AGENT_CODEX_COMMAND=codex
  AWS_SECRET_ACCESS_KEY=do-not-copy
  SUBYARD_SCRIPT_PATH="$TMP/phase.sh"
  SUBYARD_SCRIPT_ARGV=(--yes)
  warn() { :; }
  info() { :; }
  # shellcheck source=scripts/lib/engine-context.sh
  . "$ROOT/scripts/lib/engine-context.sh"
  subyard_require_engine_context
  # shellcheck source=scripts/lib/host.sh
  . "$ROOT/scripts/lib/host.sh"
  require_root fixture
)

for expected in \
  SUBYARD_ELEVATED=1 \
  SUBYARD_ENGINE_CONTEXT=1 \
  SUBYARD_ENGINE_CONTEXT_SCHEMA=1 \
  SUBYARD_USER=operator \
  "SUBYARD_OPERATOR_HOME=$TMP/operator home" \
  "SUBYARD_CONFIG_DIR=$TMP/repository/config" \
  "SUBYARD_CONFIG_HOME=$TMP/operator home/.config/subyard" \
  "SUBYARD_HOME=$TMP/operator home/.subyard" \
  "YARD_RUNTIME_ROOT=$TMP/operator home/.subyard/runtime" \
  "STORAGE_PATH=$TMP/operator home/.subyard/incus/storage" \
  "HOST_BASE=$TMP/host data" \
  "RESTRICTED_DISK_PATHS=$TMP/host data" \
  SUBYARD_YARD=e2e-yard \
  SUBYARD_YARD_EXPLICIT=1 \
  E2E_VM_IMAGE=images:debian/13/cloud \
  AGENT_CODEX_COMMAND=codex \
  "SUBYARD_POWER_ENGINE_SOURCE=$TMP/runtime/yard-engine" \
  "$TMP/phase.sh" \
  --yes; do
  grep -Fxq -- "$expected" "$MOCK_SUDO_LOG" \
    || fail "sudo re-entry omitted argument: $expected"
done
grep -Fxq -- env "$MOCK_SUDO_LOG" || fail 'sudo re-entry did not use an explicit environment'
grep -Fxq -- -n "$MOCK_SUDO_LOG" \
  || fail 'preauthorized sudo re-entry attempted an interactive password prompt'
if grep -Fq 'AWS_SECRET_ACCESS_KEY' "$MOCK_SUDO_LOG"; then
  fail 'sudo re-entry copied a non-allowlisted variable'
fi

printf 'ok: child phases own re-exec identity and preauthorized sudo preserves operator roots\n'
