#!/usr/bin/env bash
# revision-adapter.sh — encrypted immutable revision construction and publication.

[ -n "${SUBYARD_CREDENTIAL_REVISION_ADAPTER_SOURCED:-}" ] && return 0
SUBYARD_CREDENTIAL_REVISION_ADAPTER_SOURCED=1

keys_write_revision() { # repo cred label kind zone consumer syncable exclusive state parents payload recipients authority assigned epoch
  local repo="$1" cred="$2" label="$3" kind="$4" zone="$5" consumer="$6"
  local syncable="$7" exclusive="$8" state="$9" parents="${10}" payload_file="${11}"
  local recipients="${12}" authority="${13}" assigned="${14}" epoch="${15}"
  local actor counter revision dir plain out age_csv payload_b64
  actor="$(keys_actor_id)"; counter="$(keys_next_counter)"
  revision="$actor-$(printf '%012d' "$counter")-$(keys_random_hex 4)"
  dir="$repo/records/$cred"; install -d -m 700 "$dir"
  plain="$(mktemp)"; chmod 0600 "$plain"
  keys_track_secret_temp "$plain"
  out="$dir/$revision.json"
  payload_b64="$(base64 -w0 < "$payload_file")"
  "$KEYS_JQ" -n -S \
    --argjson schemaVersion "$KEYS_SCHEMA_VERSION" --arg credentialId "$cred" \
    --arg revisionId "$revision" --arg label "$label" --arg kind "$kind" --arg zone "$zone" \
    --arg scope staging --arg consumer "$consumer" --arg actorId "$actor" \
    --argjson actorCounter "$counter" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg state "$state" --argjson syncable "$syncable" --argjson exclusive "$exclusive" \
    --argjson parents "$parents" --argjson recipientActors "$recipients" \
    --arg authorityHost "$authority" --arg assignedYard "$assigned" --argjson assignmentEpoch "$epoch" \
    --arg payload "$payload_b64" \
    '{schemaVersion:$schemaVersion,credentialId:$credentialId,revisionId:$revisionId,label:$label,
      kind:$kind,zone:$zone,scope:$scope,consumer:$consumer,syncable:$syncable,exclusive:$exclusive,
      recipientActors:$recipientActors,authorityHost:$authorityHost,assignedYard:$assignedYard,
      assignmentEpoch:$assignmentEpoch,actorId:$actorId,actorCounter:$actorCounter,parents:$parents,
      timestamp:$timestamp,state:$state,payload:$payload}' > "$plain"
  age_csv="$(keys_age_csv_for_actors "$recipients")"
  if ! "$KEYS_SOPS" encrypt --age "$age_csv" --encrypted-regex '^(payload)$' \
      --input-type json --output-type json "$plain" > "$out.tmp"; then
    rm -f "$plain" "$out.tmp"; die "SOPS could not encrypt credential revision"
  fi
  chmod 0600 "$out.tmp"; mv -f "$out.tmp" "$out"; rm -f "$plain"
  keys_sign_record "$out"
  keys_git_commit "$repo" "Record $cred revision $revision"
  printf '%s\n' "$revision"
}
keys_new_credential_id() { printf 'cred-%s\n' "$(keys_random_hex 16)"; }

keys_latest_metadata() { # <repo> <credential> -> one head JSON, requires exactly one
  local heads count
  heads="$(keys_heads_json "$1" "$2")"; count="$(printf '%s' "$heads" | "$KEYS_JQ" 'length')"
  [ "$count" = 1 ] || return 1
  printf '%s\n' "$heads" | "$KEYS_JQ" '.[0]'
}

keys_add_from_file() { # label kind zone consumer local_only exclusive payload-file [credential] [parents]
  local label="$1" kind="$2" zone="$3" consumer="$4" local_only="$5" exclusive="$6" payload="$7"
  local credential="${8:-}" parents="${9:-[]}" repo recipients actor authority='' assigned='' epoch=0
  [ -n "$credential" ] || credential="$(keys_new_credential_id)"
  actor="$(keys_actor_id)"
  if [ "$local_only" = true ]; then repo="$KEYS_LOCAL"; recipients="[\"$actor\"]"; syncable=false
  else repo="$KEYS_SHARED"; keys_refresh_shared_checkout; recipients="$(keys_all_recipient_actors_json)"; syncable=true; fi
  if [ "$exclusive" = true ]; then authority="$actor"; assigned="$(keys_current_yard_id)"; epoch=1; fi
  keys_write_revision "$repo" "$credential" "$label" "$kind" "$zone" "$consumer" \
    "$syncable" "$exclusive" active "$parents" "$payload" "$recipients" "$authority" "$assigned" "$epoch" >/dev/null
  printf '%s\n' "$credential"
}
