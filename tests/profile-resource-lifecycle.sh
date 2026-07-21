#!/usr/bin/env bash
# Profile descriptors own their handlers; dispatch and representative stop/probe paths stay generic.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$TMP"
export HOME="$TMP/home" SUBYARD_NO_AUDIT=1 PATH="$TMP/bin:$PATH"
mkdir -p "$HOME" "$TMP/bin"

cat > "$TMP/bin/incus" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$RESOURCE_TEST_LOG"
case "${1:-}" in
  info) [ "${RESOURCE_TEST_UP:-1}" = 1 ] ;;
  list) printf 'RUNNING\n' ;;
  config)
    case "${2:-} ${3:-}" in
      'device list') [ "${RESOURCE_TEST_UP:-1}" = 1 ] && printf 'adb-emu\n' ;;
    esac ;;
  exec)
    [ "${RESOURCE_TEST_UP:-1}" = 1 ] || exit 1
    case " $* " in
      *' ss -Hltn '*) [ "${RESOURCE_TEST_LISTENING:-1}" = 1 ] ;;
      *' test -x /tmp/subyard-android/emulator-control.sh '*) [ "${RESOURCE_TEST_CONTROL_AVAILABLE:-1}" = 1 ] ;;
      *'emulator-control.sh is-running '*) [ "${RESOURCE_TEST_EMULATOR_PROC:-1}" = 1 ] ;;
      *'emulator-control.sh stop '*) printf 'stopped\n' ;;
      *' pgrep -u dev -f -- '*)
        [ ! -e "$RESOURCE_TEST_LEGACY_STOPPED_FILE" ] \
          && [ "${RESOURCE_TEST_EMULATOR_PROC:-1}" = 1 ] ;;
      *' pkill -TERM -u dev -f -- '* | *' pkill -KILL -u dev -f -- '*)
        : > "$RESOURCE_TEST_LEGACY_STOPPED_FILE" ;;
      *' docker inspect -f '*) printf 'true\n' ;;
    esac ;;
  file) : ;;
esac
MOCK
chmod 755 "$TMP/bin/incus"
export RESOURCE_TEST_LOG="$TMP/incus.log"
export RESOURCE_TEST_LEGACY_STOPPED_FILE="$TMP/legacy-stopped"

# shellcheck source=scripts/lib-resources.sh
. "$ROOT/scripts/lib-resources.sh"
res_registry_validate || fail 'profile resource registry validation failed'
while IFS=$'\t' read -r _profile _name _command _handler bringup shutdown verbs _title; do
  case " $verbs " in *" $bringup "*) ;; *) fail "$bringup is not a declared resource verb" ;; esac
  case " $verbs " in *" $shutdown "*) ;; *) fail "$shutdown is not a declared resource verb" ;; esac
done < <(res_rows)
if res_handler_path android '../escape.sh' >/dev/null; then
  fail 'profile resource handler escaped its owning profile'
fi
for command in emu staging qa-pool; do
  handler="$(res_handler_for_command "$command")"
  [ -x "$handler" ] || fail "$command descriptor did not resolve to an executable handler"
  case "$handler" in "$ROOT"/config/profiles/*/resources/*/handler.sh) ;; *) fail "$command handler is not profile-owned: $handler" ;; esac
  output="$("$ROOT/bin/yard" "$command" is-up)"
  [ -z "$output" ] || fail "$command is-up probe was not silent"
done

[ "$(res_handler_for_name emulator)" = "$(res_handler_for_command emu)" ] \
  || fail 'resource-name and command dispatch disagree'
[ ! -e "$ROOT/scripts/yard-emu.sh" ] && [ ! -e "$ROOT/scripts/project-staging.sh" ] \
  && [ ! -e "$ROOT/scripts/qa-pool.sh" ] || fail 'legacy core-owned profile handlers remain'

RESOURCE_TEST_UP=0
export RESOURCE_TEST_UP
for command in emu staging qa-pool; do
  if "$ROOT/bin/yard" "$command" is-up >"$TMP/$command.out" 2>&1; then
    fail "$command probe accepted a down resource"
  fi
  [ ! -s "$TMP/$command.out" ] || fail "$command down probe emitted output"
done
RESOURCE_TEST_UP=1
export RESOURCE_TEST_UP

# Controller-owned resources use their state probe and never scan the shared process table.
RESOURCE_TEST_LISTENING=0 RESOURCE_TEST_EMULATOR_PROC=1 \
  "$ROOT/bin/yard" emu status >"$TMP/emu-status.out"
grep -Fq 'still booting' "$TMP/emu-status.out" \
  || fail 'emulator status did not use its process probe while adb was down'
grep -Fq 'emulator-control.sh is-running' "$RESOURCE_TEST_LOG" \
  || fail 'emulator status did not use controller-owned state'
if grep -Fq 'pgrep -u dev -f --' "$RESOURCE_TEST_LOG"; then
  fail 'controller-owned status scanned the shared process table'
fi

# Representative reverse lifecycle paths execute through the generic dispatcher and fake Incus.
if ! "$ROOT/bin/yard" emu down --yes >"$TMP/emu-down.out" 2>&1; then
  tail -n 20 "$RESOURCE_TEST_LOG" >&2
  fail 'controller-owned emulator down failed'
fi
"$ROOT/bin/yard" staging stop --yes >/dev/null
"$ROOT/bin/yard" qa-pool down --yes >/dev/null
grep -Fq 'config device remove' "$RESOURCE_TEST_LOG" || fail 'emulator down did not remove its bridge'
grep -Fq 'emulator-control.sh stop' "$RESOURCE_TEST_LOG" \
  || fail 'emulator stop did not target its owned process group'
if grep -Fq 'pkill -TERM -u dev -f --' "$RESOURCE_TEST_LOG"; then
  fail 'controller-owned stop used the legacy process-table fallback'
fi
grep -Fq 'docker exec subyard-staging-canonical' "$RESOURCE_TEST_LOG" \
  || fail 'staging stop did not reach its profile mechanic'
grep -Fq 'docker stop subyard-qa-broker' "$RESOURCE_TEST_LOG" \
  || fail 'qa-pool down did not reach its profile mechanic'

# Before the controller's first launch, an already-running pre-upgrade emulator remains manageable.
: > "$RESOURCE_TEST_LOG"
RESOURCE_TEST_CONTROL_AVAILABLE=0 "$ROOT/bin/yard" emu down --yes >/dev/null
grep -Fq 'pkill -TERM -u dev -f -- ^(' "$RESOURCE_TEST_LOG" \
  || fail 'legacy emulator stop did not use the strict migration identity'

printf 'ok: profile-owned resources dispatch and reverse lifecycle paths remain generic\n'
