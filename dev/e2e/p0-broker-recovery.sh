#!/usr/bin/env bash
# Real disposable-host acceptance for broker logging and quarantine rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RUNNER="$ROOT/dev/agent-e2e.sh"
YARD="${SUBYARD_E2E_YARD:-test-yard}"
OUTER_PROJECT="subyard-$YARD"
OUTER_INSTANCE="yard-$YARD"
STATE_PARENT=''
NEIGHBOR_PID=''
VICTIM_PID=''
INCUS_MASKED=0

die() { printf 'p0-broker-recovery: %s\n' "$*" >&2; exit 2; }

outer_root() {
  incus exec "$OUTER_INSTANCE" --project "$OUTER_PROJECT" -- "$@"
}

stop_slot_pair() {
  local slot="$1" vm project
  project="subyard-e2e-vms-slot-$slot"
  for vm in e2e-vm-1 e2e-vm-2; do
    outer_root incus stop "$vm" --project "$project" --force
  done
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  set +e
  if [ "$INCUS_MASKED" = 1 ]; then
    outer_root systemctl unmask --runtime incus.service incus.socket >/dev/null 2>&1
    outer_root systemctl start incus.socket incus.service >/dev/null 2>&1
  fi
  for client in victim neighbor; do
    [ -z "$STATE_PARENT" ] || : > "$STATE_PARENT/$client.release"
  done
  for pid in "$VICTIM_PID" "$NEIGHBOR_PID"; do
    [ -z "$pid" ] || kill "$pid" >/dev/null 2>&1 || true
    [ -z "$pid" ] || wait "$pid" >/dev/null 2>&1 || true
  done
  if [ -n "$STATE_PARENT" ]; then
    case "$STATE_PARENT" in
      /tmp/subyard-p0-broker-recovery.*)
        find "$STATE_PARENT" -depth -delete >/dev/null 2>&1
        ;;
      *) rc=3 ;;
    esac
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

status() {
  SUBYARD_E2E_STATE_DIR="$STATE_PARENT/probe" "$RUNNER" --yard "$YARD" --status --json
}

wait_for_ready() {
  local client="$1" pid="$2"
  for _ in $(seq 1 360); do
    [ ! -s "$STATE_PARENT/$client.ready" ] || return 0
    if [ -s "$STATE_PARENT/$client.failed" ] || ! kill -0 "$pid" >/dev/null 2>&1; then
      sed -n '1,240p' "$STATE_PARENT/$client.log" >&2
      return 1
    fi
    sleep 1
  done
  sed -n '1,240p' "$STATE_PARENT/$client.log" >&2
  return 1
}

hold_lease() (
  local client="$1" purpose="$2" requested_slot="$3" ready_temp
  export SUBYARD_E2E_STATE_DIR="$STATE_PARENT/$client"
  export SUBYARD_E2E_PROJECT_LABEL="fixture/broker-recovery-$client"
  export SUBYARD_E2E_YARD="$YARD"
  # shellcheck source=dev/agent-e2e.sh
  . "$RUNNER"

  LOCAL_TEMP="$(mktemp -d "$STATE_PARENT/$client-runtime.XXXXXX")"
  LEASE_PURPOSE="$purpose"
  LEASE_REQUESTED_SLOT="$requested_slot"
  holder_cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    if [ -n "$LEASE_KEEPER_PID" ]; then
      kill "$LEASE_KEEPER_PID" >/dev/null 2>&1 || true
      wait "$LEASE_KEEPER_PID" >/dev/null 2>&1 || true
      LEASE_KEEPER_PID=''
    fi
    release_lease || rc=1
    exit "$rc"
  }
  trap holder_cleanup EXIT INT TERM

  acquire_lease || { : > "$STATE_PARENT/$client.failed"; exit 1; }
  start_lease_keeper
  ready_temp="$(mktemp "$STATE_PARENT/.$client.ready.XXXXXX")"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$LEASE_SLOT" "$CLIENT_CONFIG" "$LEASE_PROJECT" "$LEASE_RUN" "$LEASE_PURPOSE" \
    > "$ready_temp"
  mv -f "$ready_temp" "$STATE_PARENT/$client.ready"
  while [ ! -e "$STATE_PARENT/$client.release" ]; do sleep 1; done
)

install_candidate_update() {
  local arch release artifact runtime_root
  artifact="${P0_BROKER_RECOVERY_UPDATE_ARTIFACT:-}"
  if [ -z "$artifact" ]; then
    arch="$(go env GOARCH)"
    release="$ROOT/.build/p0-broker-recovery-update"
    artifact="$release/subyard-p0-broker-recovery-update-linux-$arch"
    dev/package-engine.sh \
      --output-dir "$release" \
      --version p0-broker-recovery-update \
      --arch "$arch" >/dev/null
  fi
  for input in \
    "$artifact.tar.gz" \
    "$artifact.tar.gz.sha256" \
    "$artifact.tar.gz.manifest.json" \
    "$artifact.tar.gz.provenance.json"; do
    [ -f "$input" ] && [ ! -L "$input" ] \
      || die "prepared candidate update input is unavailable: $input"
  done
  runtime_root="${SUBYARD_HOME:-$HOME/.subyard}/runtime"
  scripts/install-runtime-release.sh \
    --runtime-root "$runtime_root" \
    --bundle "$artifact.tar.gz" \
    --checksum "$artifact.tar.gz.sha256" \
    --manifest "$artifact.tar.gz.manifest.json" \
    --provenance "$artifact.tar.gz.provenance.json" >/dev/null
}

rollback_candidate_update() {
  local runtime_root="${SUBYARD_HOME:-$HOME/.subyard}/runtime"
  "$runtime_root/current/scripts/install-runtime-release.sh" \
    --runtime-root "$runtime_root" --rollback >/dev/null
}

wait_for_slot_state() {
  local slot="$1" wanted="$2" attempts="$3" payload state
  for _ in $(seq 1 "$attempts"); do
    payload="$(status)"
    state="$(jq -r --arg slot "$slot" \
      '.pool.slots[] | select(.slot_id == $slot) | .state' <<<"$payload")"
    if [ "$state" = "$wanted" ]; then
      printf '%s\n' "$payload"
      return 0
    fi
    sleep 2
  done
  printf '%s\n' "$payload" >&2
  return 1
}

report_slot_diagnostics() {
  local slot="$1" label="$2" payload incident_id incident slot_number
  printf 'p0-broker-recovery: diagnostics for %s (%s)\n' "$slot" "$label" >&2
  if payload="$(status 2>&1)"; then
    printf '%s\n' "$payload" >&2
    incident_id="$(jq -r --arg slot "$slot" '
      .pool.slots[] | select(.slot_id == $slot) | .incident_id // empty
    ' <<<"$payload")"
  else
    printf '%s\n' "$payload" >&2
    incident_id=''
  fi
  sudo -n systemctl start subyard-test-vms-host-sink.service >/dev/null 2>&1 || true
  slot_number="${slot#slot-}"
  slot_number="$((10#$slot_number))"
  ./bin/yard test-vms logs -n 200 --slot "$slot_number" >&2 || true
  if [[ "$incident_id" =~ ^[0-9]{20}-[0-9a-f]{16}$ ]]; then
    incident="$SUBYARD_HOME/logs/test-vms-broker-incidents/$incident_id.json"
    if [ -f "$incident" ] && [ ! -L "$incident" ]; then
      jq '{
        schema_version,
        incident_id,
        created_at,
        slot_id,
        resource_generation,
        lease_epoch,
        failure_reason,
        context,
        command
      }' "$incident" >&2 || true
    fi
  fi
  outer_root journalctl \
    -u subyard-test-vms-broker.service -n 80 --no-pager >&2 || true
}

[ "${SUBYARD_E2E_VM:-}" = 1 ] \
  || die 'run on VM1 through dev/agent-e2e.sh'
command -v jq >/dev/null 2>&1 || die 'jq is required'
command -v incus >/dev/null 2>&1 || die 'Incus is required'
command -v go >/dev/null 2>&1 || die 'Go is required'
STATE_PARENT="$(mktemp -d /tmp/subyard-p0-broker-recovery.XXXXXX)"
for client in neighbor victim probe next; do
  SUBYARD_E2E_STATE_DIR="$STATE_PARENT/$client" \
    "$RUNNER" --yard "$YARD" --prepare >/dev/null
done

initial="$(status)"
jq -e '
  (.pool.slots | length) == 2 and
  all(.pool.slots[]; .state == "available")
' <<<"$initial" >/dev/null \
  || die 'run only against an empty two-slot candidate broker'
initial_generation="$(jq -r '
  .pool.slots[] | select(.slot_id == "slot-001") | .resource_generation
' <<<"$initial")"

hold_lease victim quarantine-victim slot-001 \
  >"$STATE_PARENT/victim.log" 2>&1 &
VICTIM_PID=$!
wait_for_ready victim "$VICTIM_PID" || die 'victim lease did not become ready'

IFS=$'\t' read -r VICTIM_SLOT VICTIM_CONFIG _ < "$STATE_PARENT/victim.ready"
[ "$VICTIM_SLOT" = slot-001 ] || die "victim received $VICTIM_SLOT"
for vm in 1 2; do
  ssh -F "$VICTIM_CONFIG" -T "e2e-vm-$vm" -- \
    touch /var/tmp/subyard-quarantine-sentinel
done
stop_slot_pair 1

neighbor_attempt=1
while true; do
  hold_lease neighbor held-neighbor slot-002 \
    >"$STATE_PARENT/neighbor.log" 2>&1 &
  NEIGHBOR_PID=$!
  if wait_for_ready neighbor "$NEIGHBOR_PID"; then
    break
  fi
  wait "$NEIGHBOR_PID" >/dev/null 2>&1 || true
  NEIGHBOR_PID=''
  report_slot_diagnostics slot-002 \
    "neighbor provisioning attempt $neighbor_attempt failed"
  [ "$neighbor_attempt" -lt 3 ] \
    || die 'neighbor lease did not become ready after 3 automatic rebuilds'
  wait_for_slot_state slot-002 available 180 >/dev/null \
    || { report_slot_diagnostics slot-002 'neighbor automatic rebuild timed out';
         die 'neighbor provisioning quarantine did not recover'; }
  for marker in \
    "$STATE_PARENT/neighbor.ready" \
    "$STATE_PARENT/neighbor.failed" \
    "$STATE_PARENT/neighbor.release"; do
    [ ! -e "$marker" ] || find "$marker" -delete
  done
  neighbor_attempt=$((neighbor_attempt + 1))
done

# A runtime mask makes the failure deterministic: HandleQuarantine cannot
# immediately restart the required daemon before status and incident evidence
# have been observed.
outer_root systemctl mask --runtime --now incus.service incus.socket >/dev/null
INCUS_MASKED=1
if outer_root incus project list --format csv -c n >/dev/null 2>&1; then
  die 'inner Incus API remained available after deterministic failure injection'
fi
: > "$STATE_PARENT/victim.release"
if wait "$VICTIM_PID"; then
  die 'victim release unexpectedly succeeded while inner Incus was unavailable'
fi
VICTIM_PID=''

quarantined="$(wait_for_slot_state slot-001 quarantined 30)" \
  || { report_slot_diagnostics slot-001 'failed release did not quarantine';
       die 'failed release did not quarantine slot-001'; }
jq -e '
  (.pool.slots[] | select(.slot_id == "slot-001")) as $victim |
  (.pool.slots[] | select(.slot_id == "slot-002")) as $neighbor |
  $victim.state == "quarantined" and
  ($victim.incident_id | test("^[0-9]{20}-[0-9a-f]{16}$")) and
  ($victim.last_failure_event_id | test("^[0-9]{20}-[0-9a-f]{16}$")) and
  ($victim | has("failure_reason") | not) and
  $neighbor.state == "held" and
  $neighbor.project == "fixture/broker-recovery-neighbor" and
  $neighbor.purpose == "held-neighbor"
' <<<"$quarantined" >/dev/null \
  || die 'quarantine status was not bounded or changed the held neighbor'
incident_id="$(jq -r '
  .pool.slots[] | select(.slot_id == "slot-001") | .incident_id
' <<<"$quarantined")"
neighbor_heartbeat="$(jq -r '
  .pool.slots[] | select(.slot_id == "slot-002") | .last_heartbeat_at
' <<<"$quarantined")"

outer_root systemctl unmask --runtime incus.service incus.socket >/dev/null
outer_root systemctl start incus.socket incus.service
INCUS_MASKED=0
outer_root systemctl is-active --quiet incus.service \
  || die 'inner Incus did not restart'
stop_slot_pair 2

# Exercise the release owner while the neighbor remains held and the incident
# and recovery schedule already exist.
install_candidate_update
rollback_candidate_update
after_rollback="$(status)"
jq -e '
  (.pool.slots[] | select(.slot_id == "slot-002")) as $neighbor |
  $neighbor.state == "held" and
  $neighbor.project == "fixture/broker-recovery-neighbor" and
  $neighbor.purpose == "held-neighbor"
' <<<"$after_rollback" >/dev/null \
  || die 'active broker update/rollback revoked or unattributed the held neighbor'
kill -0 "$NEIGHBOR_PID" >/dev/null 2>&1 \
  || { sed -n '1,240p' "$STATE_PARENT/neighbor.log" >&2;
       die 'held neighbor lost its heartbeat process during update/rollback'; }

available="$(wait_for_slot_state slot-001 available 180)" \
  || die 'root reaper did not automatically rebuild slot-001'
new_generation="$(jq -r '
  .pool.slots[] | select(.slot_id == "slot-001") | .resource_generation
' <<<"$available")"
[ "$new_generation" -eq "$((initial_generation + 1))" ] \
  || die "resource generation changed from $initial_generation to $new_generation"
jq -e '
  (.pool.slots[] | select(.slot_id == "slot-002")) as $neighbor |
  $neighbor.state == "held" and
  $neighbor.project == "fixture/broker-recovery-neighbor"
' <<<"$available" >/dev/null \
  || die 'automatic rebuild changed the held neighbor'

# Force immediate host-wide collection rather than waiting for the one-minute
# timer, then use the public global command without -Y.
sudo -n systemctl start subyard-test-vms-host-sink.service
global_log="$(./bin/yard test-vms logs -n 100000 --slot 1)"
jq -s -e --arg incident "$incident_id" '
  any(.[]; .kind == "slot.quarantined" and .incident_id == $incident) and
  any(.[]; .kind == "rebuild.delete" and .incident_id == $incident) and
  any(.[]; .kind == "rebuild.create" and .incident_id == $incident) and
  any(.[]; .kind == "recovery.available" and .incident_id == $incident)
' <<<"$global_log" >/dev/null \
  || die 'global broker log omitted the quarantine/rebuild timeline'

incident="$SUBYARD_HOME/logs/test-vms-broker-incidents/$incident_id.json"
[ -f "$incident" ] && [ ! -L "$incident" ] \
  || die 'host-wide immutable incident artifact is missing'
jq -e '
  (.failure_reason | contains("Failed to connect to local daemon")) and
  .command.command == "incus project list --format csv -c n" and
  .command.exit_code != 0 and
  (.diagnostics | type == "object")
' "$incident" >/dev/null \
  || die 'incident did not preserve the exact original command failure'
incident_hash="$(sha256sum "$incident" | awk '{print $1}')"
sudo -n systemctl start subyard-test-vms-host-sink.service
[ "$(sha256sum "$incident" | awk '{print $1}')" = "$incident_hash" ] \
  || die 'replayed sink delivery overwrote the immutable incident'

SUBYARD_E2E_STATE_DIR="$STATE_PARENT/next" \
  SUBYARD_E2E_PROJECT_LABEL=fixture/broker-recovery-next \
  "$RUNNER" --yard "$YARD" --slot 1 --purpose clean-next-lease --vm both -- \
  test ! -e /var/tmp/subyard-quarantine-sentinel

sleep 65
after_renew="$(status)"
new_neighbor_heartbeat="$(jq -r '
  .pool.slots[] | select(.slot_id == "slot-002") | .last_heartbeat_at
' <<<"$after_renew")"
[ "$new_neighbor_heartbeat" != "$neighbor_heartbeat" ] \
  || die 'held neighbor heartbeat did not advance across update/recovery'
: > "$STATE_PARENT/neighbor.release"
wait "$NEIGHBOR_PID" \
  || { sed -n '1,240p' "$STATE_PARENT/neighbor.log" >&2;
       die 'held neighbor did not release cleanly'; }
NEIGHBOR_PID=''
final="$(wait_for_slot_state slot-002 available 60)" \
  || die 'held neighbor did not return to the pool'
jq -e 'all(.pool.slots[]; .state == "available")' <<<"$final" >/dev/null \
  || die 'candidate pool was not fully reusable after acceptance'

printf 'ok: host-wide broker log, immutable incident, held rollback and automatic clean rebuild\n'
