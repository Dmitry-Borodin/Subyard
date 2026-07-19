#!/usr/bin/env bash
# yard-boot-reconcile.sh — restore initialized local yards to persisted desired power after boot.
# Installed as a root-owned host systemd oneshot by install-power-reconciler.sh. It reads no operator
# env files: all trusted input is instance-local user.subyard.* metadata plus boot.autostart=false.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-power.sh
. "$SCRIPT_DIR/lib-power.sh"

log() { printf 'subyard-power: %s\n' "$*"; }
fail() { printf 'subyard-power: FAIL: %s\n' "$*" >&2; exit 1; }

waited=0
until command -v incus >/dev/null 2>&1 && incus info >/dev/null 2>&1; do
  [ "$waited" -lt "${SUBYARD_POWER_INCUS_TIMEOUT:-60}" ] \
    || fail "Incus did not become ready within ${SUBYARD_POWER_INCUS_TIMEOUT:-60}s"
  sleep 1
  waited=$((waited + 1))
done

mapfile -t rows < <(power_managed_rows | sort)
[ "${#rows[@]}" -gt 0 ] || { log "no managed yards"; exit 0; }

bridges=()
declare -A seen_bridge=()
for row in "${rows[@]}"; do
  IFS=, read -r project instance state <<<"$row"
  desired="$(power_get "$project" "$instance" "$POWER_KEY_DESIRED")"
  initialized="$(power_get "$project" "$instance" "$POWER_KEY_INITIALIZED")"
  autostart="$(power_get "$project" "$instance" boot.autostart)"
  bridge="$(power_get "$project" "$instance" "$POWER_KEY_BRIDGE")"
  power_valid_desired "$desired" || fail "$project/$instance has invalid desired power '$desired'"
  [ "$initialized" = true ] || fail "$project/$instance is not fully initialized"
  [ "$autostart" = false ] || fail "$project/$instance has boot.autostart='$autostart' (must be false)"
  [ -n "$bridge" ] || fail "$project/$instance has no managed bridge metadata"
  if [ -z "${seen_bridge[$bridge]:-}" ]; then bridges+=("$bridge"); seen_bridge[$bridge]=1; fi
done

# A desired-stopped yard must stay off even if this service is manually restarted after somebody
# bypassed `yard start`. Stop these before route validation so they cannot retain a rogue route.
for row in "${rows[@]}"; do
  IFS=, read -r project instance state <<<"$row"
  [ "$(power_get "$project" "$instance" "$POWER_KEY_DESIRED")" = stopped ] || continue
  if [ "$(power_state "$project" "$instance")" = RUNNING ]; then
    log "stopping $project/$instance (desired=stopped)"
    power_stop_instance "$project" "$instance" || fail "could not stop $project/$instance"
  fi
done

power_host_safe "${bridges[@]}" || fail "$POWER_ERROR"

for row in "${rows[@]}"; do
  IFS=, read -r project instance state <<<"$row"
  # Re-read intent immediately before mutation so a concurrent operator stop wins.
  [ "$(power_get "$project" "$instance" "$POWER_KEY_DESIRED")" = running ] || continue
  [ "$(power_get "$project" "$instance" "$POWER_KEY_INITIALIZED")" = true ] \
    || fail "$project/$instance became uninitialized during reconcile"
  bridge="$(power_get "$project" "$instance" "$POWER_KEY_BRIDGE")"
  if [ "$(power_state "$project" "$instance")" = RUNNING ]; then
    log "$project/$instance already running"
    power_host_safe "${bridges[@]}" || fail "$POWER_ERROR"
    continue
  fi
  log "starting $project/$instance (desired=running)"
  power_start_guarded "$project" "$instance" "${bridges[@]}" || fail "$POWER_ERROR"
done

log "desired power set restored"
