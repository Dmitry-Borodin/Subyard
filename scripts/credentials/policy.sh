#!/usr/bin/env bash
# policy.sh — recipient rekey policy for trust changes.

[ -n "${SUBYARD_CREDENTIAL_POLICY_SOURCED:-}" ] && return 0
SUBYARD_CREDENTIAL_POLICY_SOURCED=1

keys_rekey_shared_for_actor() { # <actor> add|remove
  local actor="$1" mode="$2" cred head heads count payload recipients parents tmp
  keys_refresh_shared_checkout
  while IFS= read -r cred; do
    heads="$(keys_heads_json "$KEYS_SHARED" "$cred")"; count="$(printf '%s' "$heads" | "$KEYS_JQ" 'length')"
    [ "$count" = 1 ] || continue
    head="$(printf '%s' "$heads" | "$KEYS_JQ" '.[0]')"
    recipients="$(printf '%s' "$head" | "$KEYS_JQ" -c '.recipientActors')"
    if [ "$mode" = add ]; then
      recipients="$(printf '%s' "$recipients" | "$KEYS_JQ" -c --arg actor "$actor" '. + [$actor] | unique | sort')"
    else
      recipients="$(printf '%s' "$recipients" | "$KEYS_JQ" -c --arg actor "$actor" 'map(select(. != $actor)) | unique | sort')"
    fi
    [ "$(printf '%s' "$recipients" | "$KEYS_JQ" 'length')" -gt 0 ] || continue
    [ "$recipients" != "$(printf '%s' "$head" | "$KEYS_JQ" -c '.recipientActors | unique | sort')" ] || continue
    parents="[$(printf '%s' "$head" | "$KEYS_JQ" -c '.revisionId')]"
    tmp="$(mktemp)"; chmod 0600 "$tmp"
    if [ "$(printf '%s' "$head" | "$KEYS_JQ" -r '.state')" = active ]; then
      payload="$(keys_record_path "$KEYS_SHARED" "$cred" "$(printf '%s' "$head" | "$KEYS_JQ" -r '.revisionId')")"
      keys_decrypt_payload "$payload" "$tmp" || { rm -f "$tmp"; continue; }
    else : > "$tmp"; fi
    keys_write_revision "$KEYS_SHARED" "$cred" \
      "$(printf '%s' "$head" | "$KEYS_JQ" -r '.label')" "$(printf '%s' "$head" | "$KEYS_JQ" -r '.kind')" \
      "$(printf '%s' "$head" | "$KEYS_JQ" -r '.zone')" "$(printf '%s' "$head" | "$KEYS_JQ" -r '.consumer')" true \
      "$(printf '%s' "$head" | "$KEYS_JQ" -r '.exclusive')" "$(printf '%s' "$head" | "$KEYS_JQ" -r '.state')" \
      "$parents" "$tmp" "$recipients" "$(printf '%s' "$head" | "$KEYS_JQ" -r '.authorityHost')" \
      "$(printf '%s' "$head" | "$KEYS_JQ" -r '.assignedYard')" \
      "$(printf '%s' "$head" | "$KEYS_JQ" -r '.assignmentEpoch')" >/dev/null
    rm -f "$tmp"
  done < <(keys_repo_credentials "$KEYS_SHARED")
}
