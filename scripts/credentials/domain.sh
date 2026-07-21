#!/usr/bin/env bash
# domain.sh — revision-head DAG, merge compatibility and conflict policy over injected ports.

[ -n "${SUBYARD_CREDENTIAL_DOMAIN_SOURCED:-}" ] && return 0
SUBYARD_CREDENTIAL_DOMAIN_SOURCED=1
_CREDENTIAL_DOMAIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CREDENTIAL_ENGINE_ROOT="${SUBYARD_REPOSITORY_ROOT:-$(cd "$_CREDENTIAL_DOMAIN_DIR/../.." && pwd)}"

credential_policy() {
  SUBYARD_NO_AUDIT=1 "$_CREDENTIAL_ENGINE_ROOT/bin/yard" \
    _credential-policy "$@"
}

credential_metadata_array() {
  [ "$#" -gt 0 ] || { printf '[]\n'; return 0; }
  credential_json -s 'map({
    schemaVersion,credentialId,revisionId,parents,label,kind,zone,scope,consumer,state,
    recipientActors,exclusive,syncable,authorityHost,assignedYard,assignmentEpoch,
    actorId,actorCounter,timestamp
  })' "$@"
}

keys_heads_json() { # <repo> <credential-id>
  local repo="$1" credential="$2" files=()
  mapfile -t files < <(keys_record_files "$repo" "$credential")
  [ "${#files[@]}" -gt 0 ] || { printf '[]\n'; return 0; }
  credential_metadata_array "${files[@]}" | credential_policy heads "$credential"
}
keys_parent_json_from_heads() { # <heads-json>
  printf '%s' "$1" | credential_policy parents
}

keys_metadata_compatible() { # <heads-json>
  printf '%s' "$1" | credential_policy compatible
}

keys_recipient_intersection() { # <heads-json>
  printf '%s' "$1" | credential_policy recipients
}

keys_exclusive_access_decision() { # head-json actor yard authority-trusted last-success now
  credential_json -n --argjson head "$1" --arg actor "$2" --arg yard "$3" \
    --argjson authorityTrusted "$4" --argjson lastSuccess "$5" --argjson now "$6" \
    --argjson maximumAgeSeconds "${SUBYARD_KEYS_AUTHORITY_MAX_AGE:-3600}" \
    '{head:$head,actor:$actor,yard:$yard,authorityTrusted:$authorityTrusted,
      lastSuccess:$lastSuccess,now:$now,maximumAgeSeconds:$maximumAgeSeconds}' \
    | credential_policy exclusive-access
}

keys_reconcile_credential() { # <repo> <credential>; returns 0 safe/single, 2 unsafe conflict
  local repo="$1" cred="$2" heads decision terminal_state first parents recipients exclusive payload tmp hash first_hash=''
  heads="$(keys_heads_json "$repo" "$cred")"
  decision="$(printf '%s' "$heads" | credential_policy decision)" || return 2
  [ "$(printf '%s' "$decision" | credential_json -r '.requiresMerge')" = true ] || return 0
  [ "$(printf '%s' "$decision" | credential_json -r '.conflict')" = false ] || return 2
  first="$(printf '%s' "$decision" | credential_json '.template')"
  parents="$(printf '%s' "$decision" | credential_json '.parents')"
  recipients="$(printf '%s' "$decision" | credential_json '.recipients')"
  exclusive="$(printf '%s' "$decision" | credential_json -r '.exclusive')"
  terminal_state="$(printf '%s' "$decision" | credential_json -r '.state')"
  tmp="$(mktemp)"; chmod 0600 "$tmp"
  if [ "$terminal_state" = revoked ] || [ "$terminal_state" = tombstone ]; then
    : > "$tmp"
    keys_write_revision "$repo" "$cred" \
      "$(printf '%s' "$first" | credential_json -r '.label')" \
      "$(printf '%s' "$first" | credential_json -r '.kind')" \
      "$(printf '%s' "$first" | credential_json -r '.zone')" \
      "$(printf '%s' "$first" | credential_json -r '.consumer')" \
      "$(printf '%s' "$first" | credential_json -r '.syncable')" "$exclusive" "$terminal_state" "$parents" "$tmp" "$recipients" \
      "$(printf '%s' "$first" | credential_json -r '.authorityHost')" \
      "$(printf '%s' "$first" | credential_json -r '.assignedYard')" \
      "$(printf '%s' "$first" | credential_json -r '.assignmentEpoch')" >/dev/null
    rm -f "$tmp"; return 0
  fi
  while IFS= read -r revision; do
    payload="$(keys_record_path "$repo" "$cred" "$revision")"
    keys_decrypt_payload "$payload" "$tmp" || { rm -f "$tmp"; return 2; }
    hash="$(sha256sum "$tmp" | cut -d' ' -f1)"
    [ -z "$first_hash" ] && first_hash="$hash"
    [ "$hash" = "$first_hash" ] || { rm -f "$tmp"; return 2; }
  done < <(printf '%s' "$heads" | credential_json -r '.[].revisionId')
  keys_write_revision "$repo" "$cred" \
    "$(printf '%s' "$first" | credential_json -r '.label')" \
    "$(printf '%s' "$first" | credential_json -r '.kind')" \
    "$(printf '%s' "$first" | credential_json -r '.zone')" \
    "$(printf '%s' "$first" | credential_json -r '.consumer')" \
    "$(printf '%s' "$first" | credential_json -r '.syncable')" "$exclusive" active "$parents" "$tmp" "$recipients" \
    "$(printf '%s' "$first" | credential_json -r '.authorityHost')" \
    "$(printf '%s' "$first" | credential_json -r '.assignedYard')" \
    "$(printf '%s' "$first" | credential_json -r '.assignmentEpoch')" >/dev/null
  rm -f "$tmp"
}

keys_reconcile_repo() { # <repo>; prints conflicting credential ids, returns 2 if any
  local repo="$1" cred conflict=0
  while IFS= read -r cred; do
    [ -n "$cred" ] || continue
    if ! keys_reconcile_credential "$repo" "$cred"; then
      printf '%s\n' "$cred"; conflict=1
    fi
  done < <(keys_repo_credentials "$repo")
  [ "$conflict" = 0 ] || return 2
}
