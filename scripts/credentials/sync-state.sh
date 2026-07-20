#!/usr/bin/env bash
# sync-state.sh — peer retry/backoff state store.

[ -n "${SUBYARD_CREDENTIAL_SYNC_STATE_SOURCED:-}" ] && return 0
SUBYARD_CREDENTIAL_SYNC_STATE_SOURCED=1

keys_sync_state_file() { printf '%s/%s.json\n' "$KEYS_STATE_DIR" "$1"; }

keys_state_write() { # peer success(0|1) message head
  local peer="$1" success="$2" message="$3" head="${4:-}" file now last_success=0 failures=0 delay next_retry
  file="$(keys_sync_state_file "$peer")"; now="$(date +%s)"
  if [ -r "$file" ]; then
    last_success="$("$KEYS_JQ" -r '.lastSuccess // 0' "$file" 2>/dev/null || echo 0)"
    failures="$("$KEYS_JQ" -r '.consecutiveFailures // 0' "$file" 2>/dev/null || echo 0)"
  fi
  if [ "$success" = 1 ]; then
    last_success="$now"; failures=0; delay="${SUBYARD_KEYS_SUCCESS_RETRY_SECONDS:-21600}"
  else
    failures=$((failures + 1)); delay=$((300 * (1 << (failures > 6 ? 6 : failures - 1))))
    [ "$delay" -le 21600 ] || delay=21600
  fi
  next_retry=$((now + delay))
  "$KEYS_JQ" -n -S --arg peer "$peer" --argjson lastAttempt "$now" --argjson lastSuccess "$last_success" \
    --argjson consecutiveFailures "$failures" --argjson nextRetry "$next_retry" \
    --arg error "$message" --arg lastHead "$head" \
    '{peer:$peer,lastAttempt:$lastAttempt,lastSuccess:$lastSuccess,error:$error,lastHead:$lastHead,
      consecutiveFailures:$consecutiveFailures,nextRetry:$nextRetry}' \
    > "$file.tmp"
  chmod 0600 "$file.tmp"; mv -f "$file.tmp" "$file"
}
keys_state_due() { # <peer> [seconds]
  local file last=0 next=0 now minimum="${2:-3600}"
  file="$(keys_sync_state_file "$1")"
  if [ -r "$file" ]; then
    last="$("$KEYS_JQ" -r '.lastAttempt // 0' "$file")"; next="$("$KEYS_JQ" -r '.nextRetry // 0' "$file")"
  fi
  now="$(date +%s)"
  if [ "$next" -gt 0 ]; then [ "$now" -ge "$next" ]; else [ $((now - last)) -ge "$minimum" ]; fi
}
