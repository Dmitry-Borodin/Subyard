#!/usr/bin/env bash
# yard-keys.sh — host-side encrypted, versioned and synchronizable credential ledger CLI.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This command has structured subcommand help rather than only a script-header synopsis.
case "${1:-}" in -h|--help) SUBYARD_CUSTOM_HELP=1 ;; esac
# Explicit control-plane module composition (config/context loads exactly once).
# shellcheck source=scripts/lib/runtime.sh
. "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=scripts/lib/env.sh
. "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/registry.sh
. "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=scripts/lib/context.sh
. "$SCRIPT_DIR/lib/context.sh"
# shellcheck source=scripts/lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=scripts/lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
subyard_context_load
# shellcheck source=scripts/lib/cache.sh
. "$SCRIPT_DIR/lib/cache.sh"
# shellcheck source=scripts/lib-power.sh
. "$SCRIPT_DIR/lib-power.sh"
# shellcheck source=scripts/lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"
# shellcheck source=scripts/credentials/store.sh
. "$SCRIPT_DIR/credentials/store.sh"
# shellcheck source=scripts/credentials/crypto.sh
. "$SCRIPT_DIR/credentials/crypto.sh"
# shellcheck source=scripts/credentials/domain.sh
. "$SCRIPT_DIR/credentials/domain.sh"
# shellcheck source=scripts/credentials/revision-adapter.sh
. "$SCRIPT_DIR/credentials/revision-adapter.sh"
# shellcheck source=scripts/credentials/policy.sh
. "$SCRIPT_DIR/credentials/policy.sh"
# shellcheck source=scripts/credentials/sync-state.sh
. "$SCRIPT_DIR/credentials/sync-state.sh"
# shellcheck source=scripts/credentials/transport.sh
. "$SCRIPT_DIR/credentials/transport.sh"
# shellcheck source=scripts/credentials/materialize.sh
. "$SCRIPT_DIR/credentials/materialize.sh"
# shellcheck source=scripts/credentials/verification.sh
. "$SCRIPT_DIR/credentials/verification.sh"
# shellcheck source=scripts/credentials/peers.sh
. "$SCRIPT_DIR/credentials/peers.sh"
# shellcheck source=scripts/credentials/sync.sh
. "$SCRIPT_DIR/credentials/sync.sh"

trap keys_cleanup_secret_temps EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

keys_help() {
  cat <<EOF
Usage: $(yard_cmd_hint) keys <command> [args]

Host-side encrypted credential ledger (never mounted wholesale into the guest yard):
  trust @peer [--manual-only]               reciprocal crypto trust; this route syncs by default
  untrust @peer                             remove peer from new revisions (then rotate upstream)
  add <label> [options]                     read a secret from protected stdin/TTY/file
  import <file> [options] [--dry-run]       import an existing mode-0600 static consumer file
  list                                      list metadata and head state, never values
  status                                    show conflicts and auto-sync health
  history [credential-id]                   show immutable revision metadata
  sync [@peer|--all] [--now]                pull, verify, reconcile and fast-forward push
  auto-sync status|pause|resume [@peer|--all]   manage active outbound peers
  materialize [zone|--all]                  atomically render authorized consumer files
  rotate <credential-id> [--file path]      publish an explicit replacement value
  rollback <credential-id> <revision-id>    publish an old value as a new successor
  revoke <credential-id>                    publish a revoke-wins revision
  delete <credential-id>                    publish a tombstone and remove the consumer copy
  resolve <credential-id> --choose <rev>    resolve unsafe multi-head explicitly
  move <credential-id> @peer                stop old exclusive consumer and hand off

add/import options:
  --kind <opaque|api-key|telegram|qa-pool|file>   metadata only (default: opaque/file)
  --zone <name>                                  logical staging zone (default: global)
  --consumer <none|staging-env|qa-secrets|qa-pool>
  --file <mode-0600-file>                        protected input (add/rotate)
  --local-only                                   physically separate, never exported
  --exclusive                                    one assigned yard at a time

Secret values are accepted only through a protected file, stdin or a silent TTY prompt. They are
never accepted as command arguments/environment and never printed. SSH keys and mutable coding-agent
OAuth stores are intentionally outside this ledger.
EOF
}

keys_valid_token() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }
keys_valid_zone() { keys_valid_token "$1" && [ "$1" != . ] && [ "$1" != .. ]; }

keys_validate_nonprod_zone() {
  case "$1" in prod|production) die "production credentials are outside the Subyard credential ledger scope" ;; esac
}

keys_fingerprint_denied() { # <sha256>
  local hash="$1" file="${SUBYARD_KEYS_PROD_FINGERPRINTS:-$KEYS_REPO_ROOT/config/prod-fingerprints}"
  [ -r "$file" ] || return 1
  awk -v hash="$hash" '$1 ~ /^[0-9a-fA-F]{64}$/ && tolower($1)==tolower(hash) {found=1} END{exit !found}' "$file"
}

keys_reject_prod_payload() { # <protected payload file>; never prints payload/fingerprint
  local payload="$1" hash line value encoded tmp
  hash="$(sha256sum "$payload" | cut -d' ' -f1)"
  keys_fingerprint_denied "$hash" && die "credential payload matches a recorded production fingerprint; refusing import"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; *=*) value="${line#*=}" ;; *) continue ;; esac
    case "$value" in \"*\") value="${value#\"}"; value="${value%\"}" ;; \'*\') value="${value#\'}"; value="${value%\'}" ;; esac
    hash="$(printf '%s' "$value" | sha256sum | cut -d' ' -f1)"
    keys_fingerprint_denied "$hash" && die "credential payload contains a value matching a recorded production fingerprint; refusing import"
  done < "$payload"
  if "$KEYS_JQ" -e . "$payload" >/dev/null 2>&1; then
    tmp="$(mktemp)"; chmod 0600 "$tmp"
    keys_track_secret_temp "$tmp"
    while IFS= read -r encoded; do
      printf '%s' "$encoded" | base64 -d > "$tmp"
      hash="$(sha256sum "$tmp" | cut -d' ' -f1)"
      if keys_fingerprint_denied "$hash"; then
        rm -f "$tmp"; die "credential payload contains a value matching a recorded production fingerprint; refusing import"
      fi
    done < <("$KEYS_JQ" -r '.. | strings | @base64' "$payload")
    rm -f "$tmp"
  fi
}

keys_find_credential_repo() { # <credential>; sets KEYS_FOUND_REPO
  local cred="$1" found=''
  [ -d "$KEYS_SHARED/records/$cred" ] && found="$KEYS_SHARED"
  if [ -d "$KEYS_LOCAL/records/$cred" ]; then
    [ -z "$found" ] || die "credential id '$cred' exists in both ledgers"
    found="$KEYS_LOCAL"
  fi
  [ -n "$found" ] || die "unknown credential '$cred'"
  KEYS_FOUND_REPO="$found"
}

keys_capture_payload() { # <optional-file>; prints temp path
  local source="${1:-}" tmp value
  tmp="$(mktemp)"; chmod 0600 "$tmp"
  # This function runs in command substitution, so the parent cannot register the path until a
  # successful return. Its own EXIT trap covers interrupted copy/read failures in that gap.
  trap 'rm -f -- "$tmp"' EXIT
  if [ -n "$source" ]; then
    source="$(keys_validate_import_path "$source")"
    cp -- "$source" "$tmp"
  elif [ -t 0 ]; then
    read -r -s -p "Secret value (input hidden): " value; printf '\n' >&2
    [ -n "$value" ] || { rm -f "$tmp"; die "secret value is empty"; }
    printf '%s' "$value" > "$tmp"
  else
    dd status=none of="$tmp"
    [ -s "$tmp" ] || { rm -f "$tmp"; die "secret stdin was empty"; }
  fi
  trap - EXIT
  printf '%s\n' "$tmp"
}

keys_consumer_conflict() { # <consumer> <zone>
  local consumer="$1" zone="$2" repo cred heads
  [ "$consumer" != none ] || return 1
  for repo in "$KEYS_SHARED" "$KEYS_LOCAL"; do
    while IFS= read -r cred; do
      heads="$(keys_heads_json "$repo" "$cred")"
      [ "$(printf '%s' "$heads" | "$KEYS_JQ" 'length')" = 1 ] || continue
      if printf '%s' "$heads" | "$KEYS_JQ" -e --arg c "$consumer" --arg z "$zone" \
          '.[0] | .state=="active" and .consumer==$c and .zone==$z' >/dev/null; then
        printf '%s\n' "$cred"; return 0
      fi
    done < <(keys_repo_credentials "$repo")
  done
  return 1
}

cmd_add() {
  local label='' kind=opaque zone=global consumer=none source='' local_only=false exclusive=false arg conflict payload cred
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --kind) [ $# -gt 0 ] || die "--kind needs a value"; kind="$1"; shift ;;
      --zone) [ $# -gt 0 ] || die "--zone needs a value"; zone="$1"; shift ;;
      --consumer) [ $# -gt 0 ] || die "--consumer needs a value"; consumer="$1"; shift ;;
      --file) [ $# -gt 0 ] || die "--file needs a path"; source="$1"; shift ;;
      --local-only) local_only=true ;;
      --exclusive) exclusive=true ;;
      -y|--yes) ;;
      -h|--help) keys_help; return ;;
      -*) die "keys add: unknown option '$arg'" ;;
      *) [ -z "$label" ] || die "keys add takes one label"; label="$arg" ;;
    esac
  done
  [ -n "$label" ] || die "usage: $(yard_cmd_hint) keys add <label> [options]"
  [ "${#label}" -le 128 ] && [[ "$label" != *$'\n'* ]] || die "credential label is invalid"
  keys_valid_token "$kind" || die "invalid credential kind '$kind'"
  keys_valid_zone "$zone" || die "invalid credential zone '$zone'"
  keys_validate_nonprod_zone "$zone"
  case "$consumer" in none|staging-env|qa-secrets|qa-pool) ;; *) die "invalid consumer '$consumer'" ;; esac
  keys_require_initialized
  conflict="$(keys_consumer_conflict "$consumer" "$zone" || true)"
  [ -z "$conflict" ] || die "consumer $consumer/$zone is already owned by $conflict; rotate that credential instead"
  announce "Add encrypted credential '$label'" \
    "kind=$kind zone=$zone consumer=$consumer policy=$([ "$local_only" = true ] && echo local-only || echo syncable) exclusive=$exclusive" \
    "Read the value from $([ -n "$source" ] && printf 'protected file %s' "$source" || printf 'protected stdin/TTY'); it will not appear in argv, logs or output." \
    "Write a signed immutable SOPS/age revision to the host-only ledger."
  proceed_or_die
  keys_lock_acquire
  payload="$(keys_capture_payload "$source")"
  keys_track_secret_temp "$payload"
  keys_reject_prod_payload "$payload"
  cred="$(keys_add_from_file "$label" "$kind" "$zone" "$consumer" "$local_only" "$exclusive" "$payload")"
  rm -f "$payload"
  ok "added credential $cred ($label)"
}

cmd_import() {
  local source='' label='' kind=file zone='' consumer='' local_only=false exclusive=false dry=0 arg real conflict payload cred
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      --label) [ $# -gt 0 ] || die "--label needs a value"; label="$1"; shift ;;
      --kind) [ $# -gt 0 ] || die "--kind needs a value"; kind="$1"; shift ;;
      --zone) [ $# -gt 0 ] || die "--zone needs a value"; zone="$1"; shift ;;
      --consumer) [ $# -gt 0 ] || die "--consumer needs a value"; consumer="$1"; shift ;;
      --local-only) local_only=true ;;
      --exclusive) exclusive=true ;;
      --dry-run) dry=1 ;;
      -y|--yes) ;;
      -h|--help) keys_help; return ;;
      -*) die "keys import: unknown option '$arg'" ;;
      *) [ -z "$source" ] || die "keys import takes one source file"; source="$arg" ;;
    esac
  done
  [ -n "$source" ] || die "usage: $(yard_cmd_hint) keys import <file> [options] [--dry-run]"
  real="$(keys_validate_import_path "$source")"
  [ -n "$label" ] || label="$(basename "$real")"
  [ -n "$consumer" ] || consumer="$(keys_detect_consumer "$real")"
  [ -n "$zone" ] || zone="$(keys_detect_zone "$real")"
  keys_valid_token "$kind" && keys_valid_zone "$zone" || die "invalid import kind/zone"
  keys_validate_nonprod_zone "$zone"
  case "$consumer" in none|staging-env|qa-secrets|qa-pool) ;; *) die "invalid consumer '$consumer'" ;; esac
  printf 'source: %s\nlabel: %s\nkind: %s\nzone: %s\nconsumer: %s\npolicy: %s\nexclusive: %s\nsize: %s bytes\n' \
    "$real" "$label" "$kind" "$zone" "$consumer" "$([ "$local_only" = true ] && echo local-only || echo syncable)" \
    "$exclusive" "$(stat -c '%s' "$real")"
  [ "$dry" = 0 ] || { info "dry-run only; no value was read and no ledger changed"; return 0; }
  keys_require_initialized
  conflict="$(keys_consumer_conflict "$consumer" "$zone" || true)"
  [ -z "$conflict" ] || die "consumer $consumer/$zone is already owned by $conflict; rotate it instead"
  announce "Import static credential file '$label'" \
    "Read the mode-$(stat -c '%a' "$real") file only after this confirmation." \
    "Encrypt it into the $([ "$local_only" = true ] && echo local-only || echo shared) ledger and preserve the consumer mapping." \
    "Keep the source file until a verified materialize/smoke, then remove the legacy duplicate separately."
  proceed_or_die
  keys_lock_acquire
  payload="$(keys_capture_payload "$real")"
  keys_track_secret_temp "$payload"
  keys_reject_prod_payload "$payload"
  cred="$(keys_add_from_file "$label" "$kind" "$zone" "$consumer" "$local_only" "$exclusive" "$payload")"
  rm -f "$payload"
  ok "imported credential $cred; source file was kept"
}

cmd_list() {
  local repo scope cred heads count state
  keys_require_initialized
  printf 'ID\tPOLICY\tHEADS\tSTATE\tKIND\tZONE\tCONSUMER\tLABEL\n'
  for repo in "$KEYS_SHARED" "$KEYS_LOCAL"; do
    [ "$repo" = "$KEYS_SHARED" ] && scope=syncable || scope=local-only
    while IFS= read -r cred; do
      heads="$(keys_heads_json "$repo" "$cred")"; count="$(printf '%s' "$heads" | "$KEYS_JQ" 'length')"
      [ "$count" -gt 0 ] || continue
      [ "$count" = 1 ] && state="$(printf '%s' "$heads" | "$KEYS_JQ" -r '.[0].state')" || state=conflict
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$cred" "$scope" "$count" "$state" \
        "$(printf '%s' "$heads" | "$KEYS_JQ" -r '.[0].kind')" \
        "$(printf '%s' "$heads" | "$KEYS_JQ" -r '.[0].zone')" \
        "$(printf '%s' "$heads" | "$KEYS_JQ" -r '.[0].consumer')" \
        "$(printf '%s' "$heads" | "$KEYS_JQ" -r '.[0].label')"
    done < <(keys_repo_credentials "$repo")
  done
}

keys_conflict_count() {
  local repo cred heads count=0
  for repo in "$KEYS_SHARED" "$KEYS_LOCAL"; do
    while IFS= read -r cred; do
      heads="$(keys_heads_json "$repo" "$cred")"
      [ "$(printf '%s' "$heads" | "$KEYS_JQ" 'length')" -le 1 ] || count=$((count + 1))
    done < <(keys_repo_credentials "$repo")
  done
  printf '%s\n' "$count"
}

cmd_status() {
  local arg peer file state_file last_success last_attempt next_retry error now age next policy role conflicts peers=0
  for arg in "$@"; do case "$arg" in -y|--yes) ;; -h|--help) keys_help; return ;; *) die "keys status: unexpected argument '$arg'" ;; esac; done
  if ! keys_initialized; then
    info "credential ledger is not initialized (run: $(yard_cmd_hint) init)"; return 0
  fi
  conflicts="$(keys_conflict_count)"; now="$(date +%s)"
  while IFS= read -r peer; do [ -n "$peer" ] && peers=$((peers + 1)); done < <(keys_peer_names)
  printf 'keys     host=%s yard=%s root=%s peers=%s conflicts=%s\n' \
    "$(keys_actor_id)" "$KEYS_CONTEXT" "$KEYS_BASE" "$peers" "$conflicts"
  while IFS= read -r peer; do
    [ -n "$peer" ] || continue
    file="$(keys_peer_file "$peer")"; role="$(keys_peer_role "$file")" \
      || die "peer '$peer' has an invalid transport role"
    if [ "$role" = passive ]; then policy=respond-only
    elif [ "$("$KEYS_JQ" -r '.manualOnly // false' "$file")" = true ]; then policy=manual
    else policy=automatic
    fi
    if [ "$role" = passive ]; then
      printf '  peer %-16s role=%-7s policy=%-12s last-success=n/a last-attempt=n/a next-retry=n/a\n' \
        "$peer" "$role" "$policy"
      continue
    fi
    state_file="$(keys_sync_state_file "$peer")"; last_success=0; last_attempt=0; next_retry=0; error='never synced'
    if [ -r "$state_file" ]; then
      last_success="$("$KEYS_JQ" -r '.lastSuccess // 0' "$state_file")"; last_attempt="$("$KEYS_JQ" -r '.lastAttempt // 0' "$state_file")"
      next_retry="$("$KEYS_JQ" -r '.nextRetry // 0' "$state_file")"
      error="$("$KEYS_JQ" -r '.error // ""' "$state_file")"
    fi
    if [ "$last_success" -gt 0 ]; then age="$(age_human $((now - last_success))) ago"; else age=never; fi
    if [ "$next_retry" -gt "$now" ]; then next="in $(age_human $((next_retry - now)))"; else next=due; fi
    printf '  peer %-16s role=%-7s policy=%-12s last-success=%s last-attempt=%s next-retry=%s%s\n' "$peer" "$role" "$policy" "$age" \
      "$([ "$last_attempt" -gt 0 ] && age_human $((now - last_attempt)) || echo never)" \
      "$next" \
      "$([ -n "$error" ] && printf ' error=%s' "$error" || true)"
    if [ "$policy" = automatic ] && { [ "$last_success" -eq 0 ] || [ $((now - last_success)) -gt 86400 ]; }; then
      warn "credential sync with '$peer' is stale (>24h or never successful)"
    fi
  done < <(keys_peer_names)
  [ "$conflicts" = 0 ] || warn "$conflicts credential(s) need explicit resolve before materialization"
}

cmd_history() {
  local wanted="${1:-}" repo cred record
  keys_require_initialized
  printf 'CREDENTIAL\tREVISION\tACTOR\tCOUNTER\tSTATE\tPARENTS\tRECIPIENTS\tTIMESTAMP\n'
  for repo in "$KEYS_SHARED" "$KEYS_LOCAL"; do
    while IFS= read -r cred; do
      [ -z "$wanted" ] || [ "$wanted" = "$cred" ] || continue
      while IFS= read -r record; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$cred" \
          "$("$KEYS_JQ" -r '.revisionId' "$record")" "$("$KEYS_JQ" -r '.actorId' "$record")" \
          "$("$KEYS_JQ" -r '.actorCounter' "$record")" "$("$KEYS_JQ" -r '.state' "$record")" \
          "$("$KEYS_JQ" -r '.parents | join(",")' "$record")" \
          "$("$KEYS_JQ" -r '.recipientActors | join(",")' "$record")" "$("$KEYS_JQ" -r '.timestamp' "$record")"
      done < <(keys_record_files "$repo" "$cred")
    done < <(keys_repo_credentials "$repo")
  done
}

keys_publish_from_head() { # repo cred head-json state payload-file parents-json recipients-json [assigned] [epoch]
  local repo="$1" cred="$2" head="$3" state="$4" payload="$5" parents="$6" recipients="$7"
  local assigned="${8:-}" epoch="${9:-}"
  [ -n "$assigned" ] || assigned="$(printf '%s' "$head" | "$KEYS_JQ" -r '.assignedYard')"
  [ -n "$epoch" ] || epoch="$(printf '%s' "$head" | "$KEYS_JQ" -r '.assignmentEpoch')"
  keys_write_revision "$repo" "$cred" \
    "$(printf '%s' "$head" | "$KEYS_JQ" -r '.label')" "$(printf '%s' "$head" | "$KEYS_JQ" -r '.kind')" \
    "$(printf '%s' "$head" | "$KEYS_JQ" -r '.zone')" "$(printf '%s' "$head" | "$KEYS_JQ" -r '.consumer')" \
    "$(printf '%s' "$head" | "$KEYS_JQ" -r '.syncable')" "$(printf '%s' "$head" | "$KEYS_JQ" -r '.exclusive')" \
    "$state" "$parents" "$payload" "$recipients" "$(printf '%s' "$head" | "$KEYS_JQ" -r '.authorityHost')" \
    "$assigned" "$epoch" >/dev/null
}

cmd_rotate() {
  local cred="${1:-}" source='' arg repo heads head payload parents recipients
  [ -n "$cred" ] || die "usage: $(yard_cmd_hint) keys rotate <credential-id> [--file path]"
  shift || true
  while [ $# -gt 0 ]; do arg="$1"; shift; case "$arg" in --file) [ $# -gt 0 ] || die "--file needs a path"; source="$1"; shift ;; -y|--yes) ;; *) die "keys rotate: unexpected '$arg'" ;; esac; done
  keys_require_initialized; keys_find_credential_repo "$cred"; repo="$KEYS_FOUND_REPO"
  heads="$(keys_heads_json "$repo" "$cred")"; [ "$(printf '%s' "$heads" | "$KEYS_JQ" 'length')" = 1 ] \
    || die "credential '$cred' has multiple heads; use resolve --rotate"
  head="$(printf '%s' "$heads" | "$KEYS_JQ" '.[0]')"
  announce "Rotate credential '$cred'" "Publish a signed successor; history remains encrypted and immutable." \
    "Read the new value from $([ -n "$source" ] && echo "$source" || echo protected stdin/TTY)."
  proceed_or_die; keys_lock_acquire
  payload="$(keys_capture_payload "$source")"; keys_track_secret_temp "$payload"
  parents="[$(printf '%s' "$head" | "$KEYS_JQ" -c '.revisionId')]"
  keys_reject_prod_payload "$payload"
  recipients="$(printf '%s' "$head" | "$KEYS_JQ" -c '.recipientActors')"
  keys_publish_from_head "$repo" "$cred" "$head" active "$payload" "$parents" "$recipients"
  rm -f "$payload"; ok "rotated credential '$cred'"
}

cmd_rollback() {
  local cred="${1:-}" revision="${2:-}" repo heads head target payload parents recipients
  [ -n "$cred" ] && [ -n "$revision" ] || die "usage: $(yard_cmd_hint) keys rollback <credential-id> <revision-id>"
  keys_require_initialized; keys_find_credential_repo "$cred"; repo="$KEYS_FOUND_REPO"
  heads="$(keys_heads_json "$repo" "$cred")"; [ "$(printf '%s' "$heads" | "$KEYS_JQ" 'length')" = 1 ] \
    || die "credential '$cred' has multiple heads; resolve them before rollback"
  head="$(printf '%s' "$heads" | "$KEYS_JQ" '.[0]')"
  [ "$(printf '%s' "$head" | "$KEYS_JQ" -r '.state')" = active ] \
    || die "rollback cannot resurrect a revoked/deleted credential; rotate upstream and add a new credential"
  target="$(keys_record_path "$repo" "$cred" "$revision")"; [ -r "$target" ] || die "unknown revision '$revision'"
  announce "Roll back credential '$cred'" \
    "Decrypt historical revision $revision and publish its value as a new signed successor." \
    "Keep current recipients, policy and metadata; immutable history is not rewritten."
  proceed_or_die; keys_lock_acquire
  payload="$(mktemp)"; chmod 0600 "$payload"; keys_track_secret_temp "$payload"
  keys_decrypt_payload "$target" "$payload" || { rm -f "$payload"; die "historical revision cannot be decrypted"; }
  keys_reject_prod_payload "$payload"
  parents="[$(printf '%s' "$head" | "$KEYS_JQ" -c '.revisionId')]"; recipients="$(printf '%s' "$head" | "$KEYS_JQ" -c '.recipientActors')"
  keys_publish_from_head "$repo" "$cred" "$head" active "$payload" "$parents" "$recipients"
  rm -f "$payload"; ok "rolled back credential '$cred' to the value from revision '$revision'"
}

cmd_revoke() {
  local cred="${1:-}" final_state="${2:-revoked}" repo heads head parents recipients payload verb
  [ -n "$cred" ] || die "usage: $(yard_cmd_hint) keys revoke|delete <credential-id>"
  case "$final_state" in revoked) verb=Revoke ;; tombstone) verb=Delete ;; *) die "invalid terminal credential state" ;; esac
  keys_require_initialized; keys_find_credential_repo "$cred"; repo="$KEYS_FOUND_REPO"
  heads="$(keys_heads_json "$repo" "$cred")"; [ "$(printf '%s' "$heads" | "$KEYS_JQ" 'length')" -gt 0 ] || die "no revisions"
  head="$(printf '%s' "$heads" | "$KEYS_JQ" '.[0]')"; parents="$(keys_parent_json_from_heads "$heads")"
  recipients="$(keys_recipient_intersection "$heads")"; [ "$(printf '%s' "$recipients" | "$KEYS_JQ" 'length')" -gt 0 ] || recipients="[\"$(keys_actor_id)\"]"
  announce "$verb credential '$cred'" "Publish a $final_state revision that wins over concurrent active updates." \
    "Remove its current materialized consumer copy." \
    "This does not revoke plaintext already received; rotate/delete it upstream too."
  proceed_or_die; keys_lock_acquire; payload="$(mktemp)"; chmod 0600 "$payload"; : > "$payload"
  keys_publish_from_head "$repo" "$cred" "$head" "$final_state" "$payload" "$parents" "$recipients"
  rm -f "$payload"; keys_materialize_credential "$repo" "$cred" 1
  ok "credential '$cred' is $final_state"
}

cmd_resolve() {
  local cred="${1:-}" mode='' chosen='' source='' arg repo heads head chosen_file payload parents recipients
  [ -n "$cred" ] || die "usage: keys resolve <credential-id> --choose <revision>|--rotate [--file path]"
  shift || true
  while [ $# -gt 0 ]; do arg="$1"; shift; case "$arg" in
    --choose) [ $# -gt 0 ] || die "--choose needs a revision"; mode=choose; chosen="$1"; shift ;;
    --rotate) mode=rotate ;;
    --file) [ $# -gt 0 ] || die "--file needs a path"; source="$1"; shift ;;
    -y|--yes) ;; *) die "keys resolve: unexpected '$arg'" ;; esac; done
  [ -n "$mode" ] || die "resolve needs --choose or --rotate"
  keys_require_initialized; keys_find_credential_repo "$cred"; repo="$KEYS_FOUND_REPO"
  heads="$(keys_heads_json "$repo" "$cred")"; [ "$(printf '%s' "$heads" | "$KEYS_JQ" 'length')" -gt 1 ] \
    || die "credential '$cred' has no unresolved multi-head"
  parents="$(keys_parent_json_from_heads "$heads")"; recipients="$(keys_recipient_intersection "$heads")"
  [ "$(printf '%s' "$recipients" | "$KEYS_JQ" 'length')" -gt 0 ] || die "heads have no common authorized recipient"
  if [ "$mode" = choose ]; then
    chosen_file="$(keys_record_path "$repo" "$cred" "$chosen")"; [ -r "$chosen_file" ] || die "unknown revision '$chosen'"
    head="$("$KEYS_JQ" '.' "$chosen_file")"
  else head="$(printf '%s' "$heads" | "$KEYS_JQ" '.[0]')"; fi
  announce "Resolve credential '$cred'" "Create one successor with every current head as parent." \
    "$([ "$mode" = choose ] && echo "Choose encrypted value from revision $chosen." || echo "Read an explicit replacement value.")"
  proceed_or_die; keys_lock_acquire
  if [ "$mode" = choose ]; then payload="$(mktemp)"; chmod 0600 "$payload"; keys_track_secret_temp "$payload"; keys_decrypt_payload "$chosen_file" "$payload" || die "chosen revision cannot be decrypted"
  else payload="$(keys_capture_payload "$source")"; keys_track_secret_temp "$payload"; keys_reject_prod_payload "$payload"; fi
  keys_publish_from_head "$repo" "$cred" "$head" active "$payload" "$parents" "$recipients"
  rm -f "$payload"; ok "resolved credential '$cred'"
}

cmd_materialize() {
  local zone="${1:---all}"
  case "$zone" in -y|--yes) zone=--all ;; -h|--help) keys_help; return ;; --all) ;; *) keys_valid_zone "$zone" || die "invalid zone '$zone'" ;; esac
  keys_require_initialized
  announce "Materialize encrypted credentials" "Decrypt authorized active heads for zone '$zone'." \
    "Validate every head/MAC, write mode-0600 temp files on the destination filesystem, then atomically rename." \
    "Leave the last verified consumer untouched for any conflict or validation failure."
  proceed_or_die; keys_lock_acquire
  keys_materialize_all "$zone" 0 || die "one or more credentials could not be materialized"
}

cmd_sync() {
  local target='' arg rc=0 peer file role
  while [ $# -gt 0 ]; do arg="$1"; shift; case "$arg" in --all|--now|-y|--yes) ;; @*) target="${arg#@}" ;; -h|--help) keys_help; return ;; *) die "keys sync: unexpected '$arg'" ;; esac; done
  keys_require_initialized; keys_lock_acquire
  if [ -n "$target" ]; then keys_sync_peer "$target"; return; fi
  while IFS= read -r peer; do
    [ -n "$peer" ] || continue; file="$(keys_peer_file "$peer")"; role="$(keys_peer_role "$file")" \
      || die "peer '$peer' has an invalid transport role"
    [ "$role" = active ] || continue
    keys_sync_peer "$peer" || rc=1
  done < <(keys_peer_names)
  return "$rc"
}

cmd_auto_sync() {
  local action="${1:-status}" target=all peer file value role
  shift || true
  for peer in "$@"; do case "$peer" in @*) target="${peer#@}" ;; --all|-y|--yes) ;; *) die "auto-sync: unexpected '$peer'" ;; esac; done
  keys_require_initialized
  case "$action" in
    status) cmd_status ;;
    pause|resume)
      [ "$action" = pause ] && value=true || value=false
      if [ "$target" != all ]; then
        file="$(keys_peer_file "$target")"; [ -r "$file" ] || die "credential peer '$target' is not enrolled"
        role="$(keys_peer_role "$file")" || die "peer '$target' has an invalid transport role"
        [ "$role" = active ] || die "peer '$target' is passive (respond-only); register a reverse route before changing auto-sync"
      fi
      announce "$([ "$action" = pause ] && echo Pause || echo Resume) automatic encrypted credential sync" \
        "Update policy for $([ "$target" = all ] && echo all active peers || echo "active peer '$target'")." \
        "Passive peers remain respond-only; manual 'keys sync --now' remains available for active routes."
      proceed_or_die; keys_lock_acquire
      while IFS= read -r peer; do
        [ -n "$peer" ] || continue; [ "$target" = all ] || [ "$peer" = "$target" ] || continue
        file="$(keys_peer_file "$peer")"
        role="$(keys_peer_role "$file")" || die "peer '$peer' has an invalid transport role"
        [ "$role" = active ] || continue
        "$KEYS_JQ" --argjson manual "$value" '.manualOnly=$manual' "$file" > "$file.tmp"
        chmod 0600 "$file.tmp"; mv -f "$file.tmp" "$file"
      done < <(keys_peer_names)
      ok "automatic credential sync ${action}d" ;;
    *) die "auto-sync expects status, pause or resume" ;;
  esac
}

keys_assignment_exec() { # <host-actor/yard-context> <args...>
  local assignment="$1" actor context peer; shift
  actor="$(keys_assignment_actor "$assignment")" || return 1
  context="$(keys_assignment_context "$assignment")" || return 1
  if [ "$actor" = "$(keys_actor_id)" ]; then
    if [ "$context" = default ]; then env -u SUBYARD_YARD "$KEYS_REPO_ROOT/bin/yard" "$@"
    else "$KEYS_REPO_ROOT/bin/yard" -Y "$context" "$@"; fi
  else
    peer="$(keys_peer_by_actor "$actor")" || return 1; peer="$(basename "$peer" .json)"
    keys_enrolled_exec_context "$peer" "$context" "$@"
  fi
}

keys_stop_assigned_consumer() { # <host-actor/yard-context> <zone>
  local assignment="$1" zone="$2" output
  output="$(keys_assignment_exec "$assignment" staging status "$zone" 2>&1)" || return 1
  case "$output" in
    *'gateway: running'*) keys_assignment_exec "$assignment" staging stop "$zone" --yes >/dev/null ;;
  esac
}

keys_sync_assignment_host() { # <host-actor/yard-context>
  local assignment="$1" actor peer file
  actor="$(keys_assignment_actor "$assignment")" || return 1
  [ "$actor" != "$(keys_actor_id)" ] || return 0
  file="$(keys_peer_by_actor "$actor")" || return 1
  [ "$(keys_peer_role "$file")" = active ] || return 1
  peer="$(basename "$file" .json)"
  keys_sync_peer "$peer"
}

keys_refresh_assignment() { # <host-actor/yard-context>
  keys_assignment_exec "$1" _keys-exchange refresh "$(keys_actor_id)" >/dev/null
}

cmd_move() {
  local cred="${1:-}" target="${2:-}" repo heads head actor identity='' target_actor target_context target_file
  local target_assignment trusted_file='' target_peer='' current zone payload parents recipients epoch
  [ -n "$cred" ] && [[ "$target" = @* ]] || die "usage: keys move <credential-id> @peer"
  target="${target#@}"; keys_require_initialized; keys_find_credential_repo "$cred"; repo="$KEYS_FOUND_REPO"
  [ "$repo" = "$KEYS_SHARED" ] || die "local-only credentials cannot move to a peer"
  heads="$(keys_heads_json "$repo" "$cred")"; [ "$(printf '%s' "$heads" | "$KEYS_JQ" 'length')" = 1 ] || die "resolve credential heads before move"
  head="$(printf '%s' "$heads" | "$KEYS_JQ" '.[0]')"; [ "$(printf '%s' "$head" | "$KEYS_JQ" -r '.exclusive')" = true ] || die "credential '$cred' is not exclusive"
  actor="$(keys_actor_id)"; [ "$(printf '%s' "$head" | "$KEYS_JQ" -r '.authorityHost')" = "$actor" ] || die "only the immutable authority host may move this credential"
  target_file="$(keys_peer_file "$target")"
  if [ -r "$target_file" ]; then
    target_actor="$("$KEYS_JQ" -r '.actorId' "$target_file")"
    target_assignment="$(keys_peer_yard_id "$target_file")" || die "target '$target' has no active route"
    target_context="$(keys_assignment_context "$target_assignment")"
    trusted_file="$target_file"
  elif [ "$target" = "$KEYS_CONTEXT" ]; then
    target_actor="$actor"; target_context="$KEYS_CONTEXT"
  else
    keys_peer_target_resolve "$target"
    if [ "$KEYS_TARGET_TRANSPORT" = local ]; then
      target_actor="$actor"; target_context="$target"
    else
      identity="$(keys_target_exec "$target" _keys-exchange identity)" \
        || die "target '$target' has no initialized host credential ledger"
      target_actor="$(printf '%s' "$identity" | "$KEYS_JQ" -er \
        'select(.identityScope=="host") | .actorId')" || die "target '$target' returned an invalid host identity"
      target_context="${KEYS_TARGET_REMOTE_YARD:-default}"
    fi
  fi
  target_assignment="$(keys_yard_id "$target_actor" "$target_context")"
  if [ "$target_actor" != "$actor" ]; then
    [ -n "$trusted_file" ] || trusted_file="$(keys_peer_by_actor "$target_actor")" \
      || die "target host '$target' is not trusted"
    [ "$(keys_peer_role "$trusted_file")" = active ] || die "target host '$target' has no active return route"
    target_peer="$(basename "$trusted_file" .json)"
    printf '%s' "$head" | "$KEYS_JQ" -e --arg actor "$target_actor" \
      '.recipientActors | index($actor) != null' >/dev/null || die "target host '$target' is not an encrypted recipient"
  fi
  current="$(printf '%s' "$head" | "$KEYS_JQ" -r '.assignedYard')"
  if [ "$current" = "$target_assignment" ]; then
    announce "Resume exclusive credential handoff to '$target'" \
      "The signed assignment already names $target_assignment; retry ciphertext sync/materialization idempotently." \
      "Do not publish another assignment epoch or restart the old consumer."
    proceed_or_die; keys_lock_acquire
    keys_materialize_credential "$repo" "$cred" 1
    flock -u 9
    [ -z "$target_peer" ] || keys_sync_peer "$target_peer"
    [ "$target_assignment" = "$(keys_current_yard_id)" ] || keys_target_exec "$target" _keys-exchange refresh "$actor" >/dev/null
    ok "exclusive credential '$cred' is assigned and synchronized to '$target'"
    return 0
  fi
  zone="$(printf '%s' "$head" | "$KEYS_JQ" -r '.zone')"
  announce "Move exclusive credential '$cred' to '$target'" \
    "Stop and verify the old staging consumer for zone '$zone'." \
    "Publish authority assignment epoch $(( $(printf '%s' "$head" | "$KEYS_JQ" -r '.assignmentEpoch') + 1 )) for $target_assignment." \
    "Sync and materialize on the target before it may start. No force handoff is available."
  proceed_or_die; keys_lock_acquire
  keys_stop_assigned_consumer "$current" "$zone" || die "old assigned yard is unreachable or could not confirm stop; handoff aborted"
  payload="$(mktemp)"; chmod 0600 "$payload"; keys_track_secret_temp "$payload"
  keys_decrypt_payload "$(keys_record_path "$repo" "$cred" "$(printf '%s' "$head" | "$KEYS_JQ" -r '.revisionId')")" "$payload" \
    || die "current credential payload cannot be decrypted"
  parents="[$(printf '%s' "$head" | "$KEYS_JQ" -c '.revisionId')]"; recipients="$(printf '%s' "$head" | "$KEYS_JQ" -c '.recipientActors')"
  epoch=$(( $(printf '%s' "$head" | "$KEYS_JQ" -r '.assignmentEpoch') + 1 ))
  keys_publish_from_head "$repo" "$cred" "$head" active "$payload" "$parents" "$recipients" "$target_assignment" "$epoch"
  rm -f "$payload"; keys_materialize_credential "$repo" "$cred" 1
  flock -u 9
  keys_sync_assignment_host "$current" || die "handoff was published, but the old assigned host did not synchronize"
  if [ -n "$target_peer" ] && [ "$(keys_assignment_actor "$current")" != "$target_actor" ]; then
    keys_sync_peer "$target_peer" || die "handoff was published, but the target host did not synchronize"
  fi
  [ "$current" = "$(keys_current_yard_id)" ] || keys_refresh_assignment "$current" \
    || die "handoff was published, but the old assigned yard did not refresh"
  [ "$target_assignment" = "$(keys_current_yard_id)" ] || keys_target_exec "$target" _keys-exchange refresh "$actor" >/dev/null \
    || die "handoff was published, but the target yard did not materialize"
  ok "moved exclusive credential '$cred' to '$target' (epoch $epoch)"
}

cmd_check_exclusive() { # <zone>, hidden start guard
  local zone="${1:-}" cred heads head actor yard_id authority assigned state_file peer now last matches
  keys_initialized || return 0
  keys_require_initialized
  actor="$(keys_actor_id)"; yard_id="$(keys_current_yard_id)"; now="$(date +%s)"
  while IFS= read -r cred; do
    heads="$(keys_heads_json "$KEYS_SHARED" "$cred")"
    matches="$(printf '%s' "$heads" | "$KEYS_JQ" --arg zone "$zone" '[.[] | select(.exclusive==true and .zone==$zone and .state=="active")] | length')"
    [ "$matches" -gt 0 ] || continue
    [ "$(printf '%s' "$heads" | "$KEYS_JQ" 'length')" = 1 ] || die "exclusive credential '$cred' has unresolved heads"
    head="$(printf '%s' "$heads" | "$KEYS_JQ" '.[0]')"
    assigned="$(printf '%s' "$head" | "$KEYS_JQ" -r '.assignedYard')"; [ "$assigned" = "$yard_id" ] || die "exclusive credential '$cred' is assigned to another yard"
    authority="$(printf '%s' "$head" | "$KEYS_JQ" -r '.authorityHost')"
    if [ "$authority" != "$actor" ]; then
      peer="$(keys_peer_by_actor "$authority")" || die "exclusive authority for '$cred' is not trusted"
      peer="$(basename "$peer" .json)"; state_file="$(keys_sync_state_file "$peer")"; [ -r "$state_file" ] || die "no fresh authority sync for '$cred'"
      last="$("$KEYS_JQ" -r '.lastSuccess // 0' "$state_file")"; [ $((now - last)) -le "${SUBYARD_KEYS_AUTHORITY_MAX_AGE:-3600}" ] \
        || die "authority grant for '$cred' is stale; sync keys before start"
    fi
  done < <(keys_repo_credentials "$KEYS_SHARED")
}

cmd_exchange() {
  local action="${1:-}" peer identity actor file name source_actor
  shift || true
  case "$action" in
    identity) keys_require_initialized; cat "$KEYS_ID_JSON" ;;
    bare-path) keys_require_initialized; printf '%s\n' "$KEYS_SHARED_BARE" ;;
    trust-import)
      peer="${1:-}"; keys_valid_token "$peer" || die "invalid inbound peer name"
      keys_require_initialized; identity="$(dd status=none)"; [ -n "$identity" ] || die "missing peer identity"
      keys_lock_acquire; keys_store_peer "$peer" "$identity" inbound '' '' true
      actor="$(printf '%s' "$identity" | "$KEYS_JQ" -r '.actorId')"; keys_rekey_shared_for_actor "$actor" add
      ok "accepted reciprocal key trust for '$peer'" ;;
    untrust-import)
      actor="${1:-}"; keys_require_initialized; file="$(keys_peer_by_actor "$actor")" || exit 0
      name="$(basename "$file" .json)"; keys_lock_acquire; keys_rekey_shared_for_actor "$actor" remove
      rm -f "$file" "$(keys_sync_state_file "$name")"; keys_allowed_signers_rebuild ;;
    refresh)
      source_actor="${1:-}"
      if [ -n "$source_actor" ]; then
        file="$(keys_peer_by_actor "$source_actor" 2>/dev/null || true)"
        [ -z "$file" ] || keys_state_write "$(basename "$file" .json)" 1 '' "$(keys_git "$KEYS_SHARED" rev-parse main)"
      fi
      keys_exchange_refresh ;;
    *) die "unknown keys exchange action '$action'" ;;
  esac
}

cmd_auto_worker() {
  local mode="${1:---if-due}"
  [ "$#" -le 1 ] || die "_keys-auto-sync: too many arguments"
  [ "$mode" = --if-due ] || die "_keys-auto-sync: unexpected '$mode'"
  keys_initialized || return 0
  keys_sync_all 1
}

sub="${1:-}"; [ $# -gt 0 ] && shift || true
case "$sub" in
  trust) peer="${1:-}"; [ $# -gt 0 ] && shift || true; [[ "$peer" = @* ]] || die "usage: keys trust @peer [--manual-only]"; manual=false; for a in "$@"; do case "$a" in --manual-only) manual=true ;; -y|--yes) ;; *) die "trust: unexpected '$a'" ;; esac; done; keys_trust_peer "${peer#@}" "$manual" ;;
  untrust) peer="${1:-}"; [[ "$peer" = @* ]] || die "usage: keys untrust @peer"; keys_untrust_peer "${peer#@}" ;;
  add) cmd_add "$@" ;;
  import) cmd_import "$@" ;;
  list) cmd_list "$@" ;;
  status) cmd_status "$@" ;;
  history) cmd_history "$@" ;;
  sync) cmd_sync "$@" ;;
  auto-sync) cmd_auto_sync "$@" ;;
  materialize) cmd_materialize "$@" ;;
  rotate) cmd_rotate "$@" ;;
  rollback) cmd_rollback "$@" ;;
  revoke) cred="${1:-}"; cmd_revoke "$cred" revoked ;;
  delete) cred="${1:-}"; cmd_revoke "$cred" tombstone ;;
  resolve) cmd_resolve "$@" ;;
  move) cmd_move "$@" ;;
  check-exclusive) cmd_check_exclusive "$@" ;;
  _exchange) cmd_exchange "$@" ;;
  _auto-worker) cmd_auto_worker "$@" ;;
  ''|-h|--help) keys_help ;;
  *) die "unknown keys command '$sub' (run: $(yard_cmd_hint) keys --help)" ;;
esac
