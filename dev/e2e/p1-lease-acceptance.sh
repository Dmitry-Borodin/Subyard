#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RUNNER="$ROOT/dev/agent-e2e.sh"
YARD="${SUBYARD_E2E_YARD:-test-yard}"
STATE_PARENT=''
HOLDER_A=''
HOLDER_B=''

die() { printf 'p1-lease-acceptance: %s\n' "$*" >&2; exit 2; }

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  set +e
  [ -z "$HOLDER_A" ] || kill -- "-$HOLDER_A" >/dev/null 2>&1
  [ -z "$HOLDER_B" ] || kill -- "-$HOLDER_B" >/dev/null 2>&1
  [ -z "$HOLDER_A" ] || wait "$HOLDER_A" >/dev/null 2>&1
  [ -z "$HOLDER_B" ] || wait "$HOLDER_B" >/dev/null 2>&1
  if [ -n "$STATE_PARENT" ]; then
    case "$STATE_PARENT" in /tmp/subyard-p1-lease.*|"${TMPDIR:-/tmp}"/subyard-p1-lease.*)
      find "$STATE_PARENT" -depth -delete >/dev/null 2>&1
      ;;
    esac
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

command -v jq >/dev/null 2>&1 || die 'jq is required'
command -v setsid >/dev/null 2>&1 || die 'setsid is required'
STATE_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/subyard-p1-lease.XXXXXX")"
for client in a b c; do
  SUBYARD_E2E_STATE_DIR="$STATE_PARENT/$client" "$RUNNER" --yard "$YARD" --prepare >/dev/null
done

status() {
  SUBYARD_E2E_STATE_DIR="$STATE_PARENT/c" "$RUNNER" --yard "$YARD" --status
}

wait_for_state_count() {
  local state="$1" expected="$2" attempts="${3:-90}" payload count
  for _ in $(seq 1 "$attempts"); do
    payload="$(status)"
    count="$(jq --arg state "$state" '[.pool.slots[] | select(.state == $state)] | length' \
      <<<"$payload")"
    if [ "$count" = "$expected" ]; then
      printf '%s\n' "$payload"
      return 0
    fi
    if jq -e '.pool.slots[] | select(.state == "quarantined")' <<<"$payload" >/dev/null; then
      printf '%s\n' "$payload" >&2
      return 1
    fi
    sleep 2
  done
  printf '%s\n' "$payload" >&2
  return 1
}

setsid env SUBYARD_E2E_STATE_DIR="$STATE_PARENT/a" \
  "$RUNNER" --yard "$YARD" --ssh 1 -- sleep 300 \
  >"$STATE_PARENT/a.log" 2>&1 &
HOLDER_A=$!
wait_for_state_count held 1 >/dev/null \
  || { sed -n '1,240p' "$STATE_PARENT/a.log" >&2; die 'first holder did not become ready'; }

setsid env SUBYARD_E2E_STATE_DIR="$STATE_PARENT/b" \
  "$RUNNER" --yard "$YARD" --ssh 1 -- sleep 300 \
  >"$STATE_PARENT/b.log" 2>&1 &
HOLDER_B=$!
held="$(wait_for_state_count held 2)" \
  || { sed -n '1,240p' "$STATE_PARENT/b.log" >&2; die 'second holder did not become ready'; }

jq -e '
  ([.pool.slots[] | select(.state == "held") | .slot_id] | sort) ==
    ["slot-001", "slot-002"] and
  all(.pool.slots[];
    (has("client_id") or has("controller_fingerprint") or has("lease_id") or
     has("capability_hash")) | not)
' <<<"$held" >/dev/null || die 'held pool is not distinct and redacted'

set +e
SUBYARD_E2E_STATE_DIR="$STATE_PARENT/c" "$RUNNER" --yard "$YARD" --ssh 1 -- true \
  >"$STATE_PARENT/c.log" 2>&1
busy_rc=$?
set -e
[ "$busy_rc" = 4 ] \
  || { sed -n '1,120p' "$STATE_PARENT/c.log" >&2; die "third acquire returned $busy_rc, want 4"; }

kill -- "-$HOLDER_A" "-$HOLDER_B" >/dev/null 2>&1 || true
wait "$HOLDER_A" >/dev/null 2>&1 || true
wait "$HOLDER_B" >/dev/null 2>&1 || true
HOLDER_A=''
HOLDER_B=''
released="$(wait_for_state_count available 2 60)" \
  || die 'both slots did not return to available'
jq -e 'all(.pool.slots[]; .state == "available")' <<<"$released" >/dev/null \
  || die 'release left a non-available slot'

printf 'ok: two distinct leases held both slots, third acquire returned busy, both released\n'
