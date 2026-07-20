#!/usr/bin/env bash
# domain.sh — revision-head DAG, merge compatibility and conflict policy over injected ports.

[ -n "${SUBYARD_CREDENTIAL_DOMAIN_SOURCED:-}" ] && return 0
SUBYARD_CREDENTIAL_DOMAIN_SOURCED=1

keys_heads_json() { # <repo> <credential-id>
  local repo="$1" credential="$2" files=()
  mapfile -t files < <(keys_record_files "$repo" "$credential")
  [ "${#files[@]}" -gt 0 ] || { printf '[]\n'; return 0; }
  credential_json -s '
    (map(.parents[]) | unique) as $parents |
    map(select(.revisionId as $id | ($parents | index($id) | not))) |
    sort_by(.actorId,.actorCounter,.revisionId)
  ' "${files[@]}"
}
keys_parent_json_from_heads() { # <heads-json>
  printf '%s' "$1" | credential_json -c '[.[].revisionId] | unique | sort'
}

keys_metadata_compatible() { # <heads-json>
  printf '%s' "$1" | credential_json -e '
    (([.[].label] | unique | length) == 1) and (([.[].kind] | unique | length) == 1) and
    (([.[].zone] | unique | length) == 1) and (([.[].consumer] | unique | length) == 1) and
    (([.[].authorityHost] | unique | length) == 1) and (([.[].assignedYard] | unique | length) == 1) and
    (([.[].assignmentEpoch] | unique | length) == 1)
  ' >/dev/null
}

keys_recipient_intersection() { # <heads-json>
  printf '%s' "$1" | credential_json -c '
    if length==0 then [] else
      .[0].recipientActors as $first |
      [$first[] as $actor | select(all(.[]; (.recipientActors | index($actor)) != null)) | $actor] | unique | sort
    end
  '
}

keys_reconcile_credential() { # <repo> <credential>; returns 0 safe/single, 2 unsafe conflict
  local repo="$1" cred="$2" heads count states terminal_state first parents recipients exclusive payload tmp hash first_hash=''
  heads="$(keys_heads_json "$repo" "$cred")"; count="$(printf '%s' "$heads" | credential_json 'length')"
  [ "$count" -gt 1 ] || return 0
  first="$(printf '%s' "$heads" | credential_json '.[0]')"
  parents="$(keys_parent_json_from_heads "$heads")"
  recipients="$(keys_recipient_intersection "$heads")"
  [ "$(printf '%s' "$recipients" | credential_json 'length')" -gt 0 ] || return 2
  states="$(printf '%s' "$heads" | credential_json -r '[.[].state] | unique | join(" ")')"
  exclusive="$(printf '%s' "$heads" | credential_json 'any(.[]; .exclusive == true)')"
  tmp="$(mktemp)"; chmod 0600 "$tmp"
  if [[ " $states " == *" revoked "* || " $states " == *" tombstone "* ]]; then
    if [[ " $states " == *" tombstone "* ]]; then terminal_state=tombstone; else terminal_state=revoked; fi
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
  keys_metadata_compatible "$heads" || { rm -f "$tmp"; return 2; }
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
