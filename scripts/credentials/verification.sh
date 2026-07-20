#!/usr/bin/env bash
# verification.sh — untrusted revision validation and quarantine.

[ -n "${SUBYARD_CREDENTIAL_VERIFICATION_SOURCED:-}" ] && return 0
SUBYARD_CREDENTIAL_VERIFICATION_SOURCED=1

keys_quarantine_record() { # <tree-root> <record>
  local root="$1" record="$2" rel
  rel="${record#"$root"/}"; install -d -m 700 "$KEYS_QUARANTINE_DIR/$(dirname "$rel")"
  cp -p "$record" "$KEYS_QUARANTINE_DIR/$rel" 2>/dev/null || true
  [ -f "$record.sig" ] && cp -p "$record.sig" "$KEYS_QUARANTINE_DIR/$rel.sig" 2>/dev/null || true
}
keys_quarantine_records() { # <tree-root>
  local root="$1" record
  while IFS= read -r record; do keys_quarantine_record "$root" "$record"; done < <(keys_record_files "$root")
}

keys_verify_tree() { # <tree-root>; incoming untrusted checkout/archive
  local root="$1" record rel cred rev parent local_parent path duplicate actor exclusive authority assigned epoch
  local records=()
  while IFS= read -r path; do
    rel="${path#"$root"/}"
    case "$rel" in
      .ledger|records/*/*.json|records/*/*.json.sig) ;;
      *) return 1 ;;
    esac
    [ ! -L "$path" ] || return 1
  done < <(find "$root" -mindepth 1 \( -type f -o -type l \) -print)
  while IFS= read -r record; do
    if ! keys_verify_record "$record"; then
      keys_quarantine_record "$root" "$record"
      return 1
    fi
    cred="$("$KEYS_JQ" -r '.credentialId' "$record")"
    actor="$("$KEYS_JQ" -r '.actorId' "$record")"; exclusive="$("$KEYS_JQ" -r '.exclusive' "$record")"
    authority="$("$KEYS_JQ" -r '.authorityHost' "$record")"; assigned="$("$KEYS_JQ" -r '.assignedYard' "$record")"
    epoch="$("$KEYS_JQ" -r '.assignmentEpoch' "$record")"
    if [ "$exclusive" = true ]; then
      [ -n "$authority" ] && [ -n "$assigned" ] && [ "$epoch" -ge 1 ] || return 1
      [ "$("$KEYS_JQ" -r '.parents | length' "$record")" -gt 0 ] || [ "$actor" = "$authority" ] || return 1
    else
      [ -z "$authority" ] && [ -z "$assigned" ] && [ "$epoch" = 0 ] || return 1
    fi
    "$KEYS_JQ" -e '.syncable == true' "$record" >/dev/null || return 1
    while IFS= read -r parent; do
      [ -n "$parent" ] || continue
      local_parent="$root/records/$cred/$parent.json"
      [ -f "$local_parent" ] || [ -f "$KEYS_SHARED/records/$cred/$parent.json" ] || return 1
      [ -f "$local_parent" ] || local_parent="$KEYS_SHARED/records/$cred/$parent.json"
      if [ "$exclusive" = true ]; then
        [ "$("$KEYS_JQ" -r '.authorityHost' "$local_parent")" = "$authority" ] || return 1
        if [ "$("$KEYS_JQ" -r '.assignedYard' "$local_parent")" != "$assigned" ] \
            || [ "$("$KEYS_JQ" -r '.assignmentEpoch' "$local_parent")" != "$epoch" ]; then
          [ "$actor" = "$authority" ] || return 1
          [ "$epoch" -gt "$("$KEYS_JQ" -r '.assignmentEpoch' "$local_parent")" ] || return 1
        fi
      fi
    done < <("$KEYS_JQ" -r '.parents[]' "$record")
    if "$KEYS_JQ" -e --arg actor "$(keys_actor_id)" '.recipientActors | index($actor) != null' "$record" >/dev/null; then
      local tmp; tmp="$(mktemp)"; chmod 0600 "$tmp"
      keys_track_secret_temp "$tmp"
      keys_decrypt_payload "$record" "$tmp" || { rm -f "$tmp"; keys_quarantine_record "$root" "$record"; return 1; }
      rm -f "$tmp"
    fi
    rev="$("$KEYS_JQ" -r '.revisionId' "$record")"
    [ -n "$rev" ] || return 1
  done < <(keys_record_files "$root")
  duplicate="$({
    while IFS= read -r record; do
      "$KEYS_JQ" -r '[.actorId,.actorCounter,.revisionId] | @tsv' "$record"
    done < <(keys_record_files "$root")
  } | awk -F '\t' '{key=$1 FS $2; if (seen[key] && seen[key]!=$3) {print key; exit} seen[key]=$3}')"
  [ -z "$duplicate" ] || return 1
  mapfile -t records < <(keys_record_files "$root")
  [ "${#records[@]}" -gt 0 ] || return 0
  "$KEYS_JQ" -s -e '
    def acyclic:
      if length==0 then true
      else . as $nodes | (map(.revisionId)) as $ids |
        [$nodes[] | . as $node |
          select(all($node.parents[]; . as $parent | ($ids | index($parent)) == null))] as $roots |
        if ($roots|length)==0 then false
        else ($roots|map(.revisionId)) as $rootIds |
          [$nodes[] | select(.revisionId as $id | ($rootIds | index($id) | not))] | acyclic
        end
      end;
    acyclic
  ' "${records[@]}" >/dev/null || { keys_quarantine_records "$root"; return 1; }
}
