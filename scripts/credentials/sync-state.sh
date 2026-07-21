#!/usr/bin/env bash
# sync-state.sh — peer retry/backoff state store.

[ -n "${SUBYARD_CREDENTIAL_SYNC_STATE_SOURCED:-}" ] && return 0
SUBYARD_CREDENTIAL_SYNC_STATE_SOURCED=1

keys_sync_state_file() { printf '%s/%s.json\n' "$KEYS_STATE_DIR" "$1"; }

keys_state_write() { # peer success(0|1) message head
  local peer="$1" success="$2" message="$3" head="${4:-}" file now current='{}' success_json=false input
  file="$(keys_sync_state_file "$peer")"; now="$(date +%s)"
  [ ! -r "$file" ] || current="$("$KEYS_JQ" -c . "$file")"
  [ "$success" != 1 ] || success_json=true
  input="$("$KEYS_JQ" -n --argjson current "$current" --arg peer "$peer" --argjson now "$now" \
    --argjson success "$success_json" --arg error "$message" --arg lastHead "$head" \
    --argjson successRetrySeconds "${SUBYARD_KEYS_SUCCESS_RETRY_SECONDS:-21600}" \
    '{current:$current,peer:$peer,now:$now,success:$success,error:$error,lastHead:$lastHead,
      successRetrySeconds:$successRetrySeconds}')"
  printf '%s' "$input" | credential_policy sync-next > "$file.tmp"
  chmod 0600 "$file.tmp"; mv -f "$file.tmp" "$file"
}
keys_state_due() { # <peer> [seconds]
  local file state='{}' now minimum="${2:-3600}"
  file="$(keys_sync_state_file "$1")"
  [ ! -r "$file" ] || state="$("$KEYS_JQ" -c . "$file")"
  now="$(date +%s)"
  printf '%s' "$state" | credential_policy sync-due "$now" "$minimum"
}
