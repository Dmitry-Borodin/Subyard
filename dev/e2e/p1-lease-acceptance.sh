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
  [ -z "$HOLDER_A" ] || kill "$HOLDER_A" >/dev/null 2>&1
  [ -z "$HOLDER_B" ] || kill "$HOLDER_B" >/dev/null 2>&1
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
command -v ssh >/dev/null 2>&1 || die 'ssh is required'
STATE_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/subyard-p1-lease.XXXXXX")"
for client in a b c; do
  SUBYARD_E2E_STATE_DIR="$STATE_PARENT/$client" "$RUNNER" --yard "$YARD" --prepare >/dev/null
done

status() {
  SUBYARD_E2E_STATE_DIR="$STATE_PARENT/c" "$RUNNER" --yard "$YARD" --status --json
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

wait_for_ready() {
  local client="$1" pid="$2" attempts="${P1_LEASE_READY_ATTEMPTS:-360}"
  for _ in $(seq 1 "$attempts"); do
    [ ! -s "$STATE_PARENT/$client.ready" ] || return 0
    [ ! -s "$STATE_PARENT/$client.failed" ] \
      || { sed -n '1,240p' "$STATE_PARENT/$client.log" >&2; return 1; }
    kill -0 "$pid" >/dev/null 2>&1 \
      || { sed -n '1,240p' "$STATE_PARENT/$client.log" >&2; return 1; }
    sleep 1
  done
  sed -n '1,240p' "$STATE_PARENT/$client.log" >&2
  return 1
}

wait_for_guest_access() {
  local client="$1" config="$2" attempts="${P1_LEASE_SSH_ATTEMPTS:-12}"
  local log="$STATE_PARENT/$client-ssh.log"
  for _ in $(seq 1 "$attempts"); do
    if ssh -F "$config" -T -o ConnectTimeout=5 e2e-vm-1 -- true \
      </dev/null >"$log" 2>&1; then
      rm -f "$log"
      return 0
    fi
    sleep 2
  done
  sed -n '1,120p' "$log" >&2
  return 1
}

hold_lease() (
  local client="$1" project="$2" purpose="$3" requested_slot="$4" ready_temp
  export SUBYARD_E2E_STATE_DIR="$STATE_PARENT/$client"
  export SUBYARD_E2E_PROJECT_LABEL="$project"
  export SUBYARD_E2E_YARD="$YARD"
  # shellcheck source=dev/agent-e2e.sh
  . "$RUNNER"

  LOCAL_TEMP="$(mktemp -d "$STATE_PARENT/$client-runtime.XXXXXX")"
  LEASE_PURPOSE="$purpose"
  LEASE_REQUESTED_SLOT="$requested_slot"
  holder_cleanup() {
    local rc=$? release_failed=0
    trap - EXIT INT TERM
    set +e
    if [ -n "$LEASE_KEEPER_PID" ]; then
      kill "$LEASE_KEEPER_PID" >/dev/null 2>&1 || true
      wait "$LEASE_KEEPER_PID" >/dev/null 2>&1 || true
      LEASE_KEEPER_PID=''
    fi
    release_lease || release_failed=1
    [ "$release_failed" = 0 ] || rc=1
    exit "$rc"
  }
  trap holder_cleanup EXIT
  trap 'exit 143' INT TERM

  acquire_lease || { : > "$STATE_PARENT/$client.failed"; exit 1; }
  start_lease_keeper
  printf '%s\n' \
    'set -eu' \
    'jq -e --arg project "$1" --arg checkout "$2" --arg run "$3" --arg purpose "$4" '\''.schema_version == 1 and .project == $project and .checkout == $checkout and .run == $run and .purpose == $purpose'\'' /run/subyard-e2e-lease.json >/dev/null' \
    | guest 1 sh -s -- "$LEASE_PROJECT" "$LEASE_CHECKOUT" "$LEASE_RUN" "$LEASE_PURPOSE"
  guest 2 jq -e \
    --arg project "$LEASE_PROJECT" \
    --arg checkout "$LEASE_CHECKOUT" \
    --arg run "$LEASE_RUN" \
    --arg purpose "$LEASE_PURPOSE" \
    '.schema_version == 1 and .project == $project and .checkout == $checkout and
      .run == $run and .purpose == $purpose' \
    /run/subyard-e2e-lease.json >/dev/null

  umask 077
  printf '%s\n' "$(lease_command renew)" > "$STATE_PARENT/$client.stale-renew"
  ready_temp="$(mktemp "$STATE_PARENT/.$client.ready.XXXXXX")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$LEASE_SLOT" "$LEASE_PROJECT" "$LEASE_CHECKOUT" "$LEASE_RUN" "$LEASE_PURPOSE" \
    "$CLIENT_CONFIG" "$GUEST_IDENTITY" "$GUEST_KNOWN_HOSTS" "${VM_IP[1]}" "${VM_IP[2]}" \
    > "$ready_temp"
  mv -f "$ready_temp" "$STATE_PARENT/$client.ready"
  while [ ! -e "$STATE_PARENT/$client.release" ]; do sleep 1; done
)

stale_renew() (
  local client="$1"
  export SUBYARD_E2E_STATE_DIR="$STATE_PARENT/$client"
  export SUBYARD_E2E_YARD="$YARD"
  # shellcheck source=dev/agent-e2e.sh
  . "$RUNNER"
  facade_request "$(cat "$STATE_PARENT/$client.stale-renew")"
)

initial="$(status)"
jq -e '
  (.pool.slots | length) == 2 and
  all(.pool.slots[]; .state == "available")
' <<<"$initial" >/dev/null \
  || die 'run only against an empty two-slot candidate broker'

hold_lease b fixture/project-b holder-b slot-002 \
  >"$STATE_PARENT/b.log" 2>&1 &
HOLDER_B=$!
wait_for_ready b "$HOLDER_B" || die 'second holder did not become ready'
wait_for_state_count held 1 >/dev/null \
  || { sed -n '1,240p' "$STATE_PARENT/b.log" >&2; die 'second holder was not published'; }
IFS=$'\t' read -r -a B_READY < "$STATE_PARENT/b.ready"
B_SLOT="${B_READY[0]}"
B_CONFIG="${B_READY[5]}"
B_KNOWN_HOSTS="${B_READY[7]}"
B_IP1="${B_READY[8]}"
[ "$B_SLOT" = slot-002 ] || die "exact holder B received $B_SLOT"

set +e
SUBYARD_E2E_STATE_DIR="$STATE_PARENT/c" SUBYARD_E2E_PROJECT_LABEL=fixture/project-c \
  "$RUNNER" --yard "$YARD" --slot 2 --purpose exact-slot-busy --ssh 1 -- true \
  >"$STATE_PARENT/exact-busy.log" 2>&1
exact_busy_rc=$?
set -e
[ "$exact_busy_rc" = 2 ] \
  || { sed -n '1,120p' "$STATE_PARENT/exact-busy.log" >&2;
       die "occupied exact-slot acquire returned $exact_busy_rc, want 2"; }
grep -Fq 'requested E2E slot slot-002 is not available' "$STATE_PARENT/exact-busy.log" \
  || die 'occupied exact-slot acquire did not fail explicitly'
exact_busy_state="$(status)"
jq -e '
  (.pool.slots[] | select(.slot_id == "slot-001") | .state) == "available" and
  (.pool.slots[] | select(.slot_id == "slot-002") | .state) == "held"
' <<<"$exact_busy_state" >/dev/null \
  || die 'occupied exact-slot acquire fell back or changed its neighbor'

hold_lease a fixture/project-a holder-a slot-001 \
  >"$STATE_PARENT/a.log" 2>&1 &
HOLDER_A=$!
wait_for_ready a "$HOLDER_A" || die 'first holder did not become ready'
held="$(wait_for_state_count held 2)" \
  || { sed -n '1,240p' "$STATE_PARENT/a.log" >&2; die 'first holder was not published'; }
IFS=$'\t' read -r -a A_READY < "$STATE_PARENT/a.ready"
A_SLOT="${A_READY[0]}"
A_CONFIG="${A_READY[5]}"
A_KEY="${A_READY[6]}"
[ "$A_SLOT" = slot-001 ] || die "exact holder A received $A_SLOT"

jq -e '
  ([.pool.slots[] | select(.state == "held") | .slot_id] | sort) ==
    ["slot-001", "slot-002"] and
  ([.pool.slots[] | select(.state == "held") | .project] | sort) ==
    ["fixture/project-a", "fixture/project-b"] and
  ([.pool.slots[] | select(.state == "held") | .purpose] | sort) ==
    ["holder-a", "holder-b"] and
  all(.pool.slots[] | select(.state == "held");
    (.checkout | test("^[0-9a-f]{8}$")) and (.run | test("^[0-9a-f]{8}$"))) and
  all(.pool.slots[];
    (has("client_id") or has("controller_fingerprint") or has("lease_id") or
     has("capability_hash") or has("targets") or has("address") or
     has("host_key_blob")) | not)
' <<<"$held" >/dev/null || die 'held pool is not distinct and redacted'
grep -Eq "^E2E lease: project=fixture/project-a .* purpose=holder-a slot=$A_SLOT$" \
  "$STATE_PARENT/a.log" \
  || die 'first holder did not print its attributed cross-project reuse'
grep -Eq '^E2E lease: project=fixture/project-b .* purpose=holder-b slot=slot-[0-9]{3}$' \
  "$STATE_PARENT/b.log" || die 'second holder did not print its attributed assignment'
for log in "$STATE_PARENT/a.log" "$STATE_PARENT/b.log"; do
  ! grep '^E2E lease:' "$log" | grep -Eq \
    '([0-9]{1,3}\.){3}[0-9]{1,3}|lease_id|capability|/tmp/|/home/' \
    || die 'assignment banner disclosed an endpoint, credential or private path'
done

wait_for_guest_access a "$A_CONFIG" \
  || die 'holder A could not reach its own guest'
wait_for_guest_access b "$B_CONFIG" \
  || die 'holder B could not reach its own guest'
if ssh -F "$A_CONFIG" -T -o ConnectTimeout=5 -W "$B_IP1:22" subyard-e2e-data \
  </dev/null >/dev/null 2>&1; then
  die 'holder A data account forwarded to holder B'
fi
if ssh -F /dev/null -T -o ConnectTimeout=5 -o HostName="$B_IP1" -o User=root \
  -o IdentityFile="$A_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$B_KNOWN_HOSTS" \
  -o HostKeyAlias=e2e-vm-1 -o ProxyJump=none \
  -o "ProxyCommand=ssh -F $B_CONFIG -T -W %h:%p subyard-e2e-data" \
  holder-b-with-a-key -- true </dev/null >/dev/null 2>&1; then
  die 'holder A ephemeral key authenticated to holder B guest'
fi
if printf '%s\n' \
  'set -eu' \
  'if timeout 3 bash -c "</dev/tcp/$1/22" 2>/dev/null; then exit 42; fi' \
  | ssh -F "$A_CONFIG" -T e2e-vm-1 -- bash -s -- "$B_IP1"; then
  :
else
  case "$?" in
    42) die 'holder A guest root reached holder B slot network' ;;
    *) die 'holder A guest-network isolation probe failed unexpectedly' ;;
  esac
fi

set +e
SUBYARD_E2E_STATE_DIR="$STATE_PARENT/c" SUBYARD_E2E_PROJECT_LABEL=fixture/project-c \
  "$RUNNER" --yard "$YARD" --purpose holder-c --ssh 1 -- true \
  >"$STATE_PARENT/c.log" 2>&1
busy_rc=$?
set -e
[ "$busy_rc" = 4 ] \
  || { sed -n '1,120p' "$STATE_PARENT/c.log" >&2; die "third acquire returned $busy_rc, want 4"; }
grep -Fq 'agent-e2e: pool busy' "$STATE_PARENT/c.log" \
  && grep -Fq 'fixture/project-a' "$STATE_PARENT/c.log" \
  && grep -Fq 'fixture/project-b' "$STATE_PARENT/c.log" \
  || { sed -n '1,120p' "$STATE_PARENT/c.log" >&2; die 'busy output omitted holders'; }

: > "$STATE_PARENT/b.release"
if ! wait "$HOLDER_B"; then
  sed -n '1,240p' "$STATE_PARENT/b.log" >&2
  die 'holder B release command failed'
fi
HOLDER_B=''
wait_for_state_count held 1 60 >/dev/null \
  || die 'holder B did not release its slot'
if ssh -F "$B_CONFIG" -T -o ConnectTimeout=5 e2e-vm-1 -- true \
  </dev/null >/dev/null 2>&1; then
  die 'holder B stale SSH configuration survived release'
fi
stale_response="$(stale_renew b)"
[ "$(jq -r '.code // empty' <<<"$stale_response")" = lease_lost ] \
  || die 'holder B stale capability survived release'

sleep 1
: > "$STATE_PARENT/a.release"
if ! wait "$HOLDER_A"; then
  sed -n '1,240p' "$STATE_PARENT/a.log" >&2
  die 'holder A release command failed'
fi
HOLDER_A=''
released="$(wait_for_state_count available 2 60)" \
  || die 'both slots did not return to available'
jq -e 'all(.pool.slots[]; .state == "available")' <<<"$released" >/dev/null \
  || die 'release left a non-available slot'
printf 'ok: attributed holders were isolated, fenced and released\n'
