#!/usr/bin/env bash
# materialize.sh — protected consumer-file mapping and atomic materialization.

[ -n "${SUBYARD_CREDENTIAL_MATERIALIZE_SOURCED:-}" ] && return 0
SUBYARD_CREDENTIAL_MATERIALIZE_SOURCED=1

keys_consumer_path() { # <consumer> <zone>
  case "$1" in
    none|'') return 1 ;;
    staging-env) printf '%s/config/staging/%s.env\n' "$KEYS_CONSUMER_ROOT" "$2" ;;
    qa-secrets) printf '%s/config/qa-pool/secrets.env\n' "$KEYS_CONSUMER_ROOT" ;;
    qa-pool) printf '%s/config/qa-pool/pool.jsonl\n' "$KEYS_CONSUMER_ROOT" ;;
    *) return 1 ;;
  esac
}
keys_materialize_credential() { # <repo> <credential> [automatic:0|1]
  local repo="$1" cred="$2" automatic="${3:-0}" head heads count state recipient actor consumer zone dest payload tmp
  local exclusive authority peer state_file last now trusted decision reason
  heads="$(keys_heads_json "$repo" "$cred")"; count="$(printf '%s' "$heads" | "$KEYS_JQ" 'length')"
  [ "$count" = 1 ] || { [ "$automatic" = 1 ] || warn "$cred has $count heads; resolve before materializing"; return 2; }
  head="$(printf '%s' "$heads" | "$KEYS_JQ" '.[0]')"; state="$(printf '%s' "$head" | "$KEYS_JQ" -r '.state')"
  consumer="$(printf '%s' "$head" | "$KEYS_JQ" -r '.consumer')"; zone="$(printf '%s' "$head" | "$KEYS_JQ" -r '.zone')"
  dest="$(keys_consumer_path "$consumer" "$zone")" || return 0
  if [ "$state" != active ]; then
    if [ -e "$dest" ]; then
      rm -f -- "$dest"
      [ "$automatic" = 1 ] || ok "removed revoked consumer $dest"
    fi
    return 0
  fi
  actor="$(keys_actor_id)"
  recipient="$(printf '%s' "$head" | "$KEYS_JQ" -r --arg actor "$actor" '.recipientActors | index($actor) // empty')"
  [ -n "$recipient" ] || return 0
  exclusive="$(printf '%s' "$head" | "$KEYS_JQ" -r '.exclusive')"
  if [ "$exclusive" = true ]; then
    authority="$(printf '%s' "$head" | "$KEYS_JQ" -r '.authorityHost')"
    trusted=false; last=0; now="$(date +%s)"
    if [ "$authority" != "$actor" ]; then
      peer="$(keys_peer_by_actor "$authority" || true)"
      if [ -n "$peer" ]; then
        trusted=true; state_file="$(keys_sync_state_file "$(basename "$peer" .json)")"
        [ ! -r "$state_file" ] || last="$("$KEYS_JQ" -r '.lastSuccess // 0' "$state_file")"
      fi
    fi
    decision="$(keys_exclusive_access_decision "$head" "$actor" "$(keys_current_yard_id)" "$trusted" "$last" "$now")" \
      || { [ "$automatic" = 1 ] || warn "$cred has invalid exclusive access metadata"; return 1; }
    reason="$(printf '%s' "$decision" | "$KEYS_JQ" -r '.reason')"
    case "$reason" in
      authority-local|authority-fresh) ;;
      not-assigned) [ ! -e "$dest" ] || rm -f -- "$dest"; return 0 ;;
      authority-untrusted) [ "$automatic" = 1 ] || warn "$cred has no trusted authority"; return 1 ;;
      authority-stale) [ "$automatic" = 1 ] || warn "$cred has no fresh authority exchange"; return 1 ;;
      *) [ "$automatic" = 1 ] || warn "$cred has an invalid exclusive access decision"; return 1 ;;
    esac
  fi
  payload="$(keys_record_path "$repo" "$cred" "$(printf '%s' "$head" | "$KEYS_JQ" -r '.revisionId')")"
  install -d -m 700 "$(dirname "$dest")"
  tmp="$(mktemp "$(dirname "$dest")/.subyard-key.XXXXXX")"; chmod 0600 "$tmp"
  keys_track_secret_temp "$tmp"
  keys_decrypt_payload "$payload" "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dest"; chmod 0600 "$dest"
  [ "$automatic" = 1 ] || ok "materialized $cred -> $dest"
}

keys_materialize_all() { # [zone] [automatic]
  local zone="${1:-}" automatic="${2:-0}" repo cred heads record_zone rc=0
  for repo in "$KEYS_SHARED" "$KEYS_LOCAL"; do
    while IFS= read -r cred; do
      [ -n "$cred" ] || continue
      heads="$(keys_heads_json "$repo" "$cred")"
      [ "$(printf '%s' "$heads" | "$KEYS_JQ" 'length')" = 1 ] || { rc=2; continue; }
      record_zone="$(printf '%s' "$heads" | "$KEYS_JQ" -r '.[0].zone')"
      [ -z "$zone" ] || [ "$zone" = --all ] || [ "$record_zone" = "$zone" ] || continue
      keys_materialize_credential "$repo" "$cred" "$automatic" || rc=$?
    done < <(keys_repo_credentials "$repo")
  done
  return "$rc"
}

keys_validate_import_path() { # <path>
  local path="$1" real
  [ -f "$path" ] || die "credential source is not a regular file: $path"
  [ ! -L "$path" ] || die "credential import refuses symlinks: $path"
  real="$(realpath "$path")"
  case "$real" in
    */.codex/*|*/.claude/*|*/.pi/*|*/.config/opencode/*|*/auth.json|*/credentials/oauth.json|/srv/staging/*/creds/*)
      die "mutable coding-agent/OAuth stores cannot be imported into the credential ledger: $path" ;;
  esac
  case "$(stat -c '%a' "$real")" in 600|400) ;; *) die "credential source must have mode 0600 or 0400: $path" ;; esac
  printf '%s\n' "$real"
}

keys_detect_consumer() { # <real-path>
  case "$1" in
    "$KEYS_CONSUMER_ROOT"/config/staging/*.env) printf 'staging-env\n' ;;
    "$KEYS_CONSUMER_ROOT"/config/qa-pool/secrets.env) printf 'qa-secrets\n' ;;
    "$KEYS_CONSUMER_ROOT"/config/qa-pool/pool.jsonl) printf 'qa-pool\n' ;;
    *) printf 'none\n' ;;
  esac
}

keys_detect_zone() { # <real-path>
  case "$1" in "$KEYS_CONSUMER_ROOT"/config/staging/*.env) basename "$1" .env ;; *) printf 'global\n' ;; esac
}
