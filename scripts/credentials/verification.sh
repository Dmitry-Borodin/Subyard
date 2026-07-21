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
  local root="$1" record rel path incoming existing
  local records=() existing_records=()
  while IFS= read -r path; do
    rel="${path#"$root"/}"
    case "$rel" in
      .ledger|records/*/*.json|records/*/*.json.sig) ;;
      *) return 1 ;;
    esac
    [ ! -L "$path" ] || return 1
  done < <(find "$root" -mindepth 1 \( -type f -o -type l \) -print)
  mapfile -t records < <(keys_record_files "$root")
  for record in "${records[@]}"; do
    if ! keys_verify_record "$record"; then
      keys_quarantine_record "$root" "$record"
      return 1
    fi
  done
  mapfile -t existing_records < <(keys_record_files "$KEYS_SHARED")
  incoming="$(credential_metadata_array "${records[@]}")"
  existing="$(credential_metadata_array "${existing_records[@]}")"
  if ! "$KEYS_JQ" -n --argjson incoming "$incoming" --argjson existing "$existing" \
      '{incoming:$incoming,existing:$existing}' | credential_policy validate-incoming; then
    keys_quarantine_records "$root"
    return 1
  fi
  for record in "${records[@]}"; do
    if "$KEYS_JQ" -e --arg actor "$(keys_actor_id)" '.recipientActors | index($actor) != null' "$record" >/dev/null; then
      local tmp; tmp="$(mktemp)"; chmod 0600 "$tmp"
      keys_track_secret_temp "$tmp"
      keys_decrypt_payload "$record" "$tmp" || { rm -f "$tmp"; keys_quarantine_record "$root" "$record"; return 1; }
      rm -f "$tmp"
    fi
  done
}
