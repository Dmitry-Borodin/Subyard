#!/usr/bin/env bash
# lib-keys.sh — host-side encrypted/versioned credential ledger primitives.
# Source after lib.sh. The store is never mounted into a yard; shared Git contains ciphertext only.

[ -n "${SUBYARD_KEYS_LIB_SOURCED:-}" ] && return 0
SUBYARD_KEYS_LIB_SOURCED=1

KEYS_SCHEMA_VERSION=1
KEYS_CONTEXT="${YARD_NAME:-default}"
KEYS_ROOT="${SUBYARD_KEYS_ROOT:-$SUBYARD_CONFIG_HOME/keys}"
KEYS_BASE="$KEYS_ROOT"
KEYS_ID_DIR="$KEYS_BASE/identity"
KEYS_AGE_ID="$KEYS_ID_DIR/age.txt"
KEYS_SIGN_KEY="$KEYS_ID_DIR/signing_ed25519"
KEYS_SIGN_PUB="$KEYS_SIGN_KEY.pub"
KEYS_ID_JSON="$KEYS_BASE/identity.json"
KEYS_ALLOWED_SIGNERS="$KEYS_BASE/allowed_signers"
KEYS_PEERS_DIR="$KEYS_BASE/peers"
KEYS_STATE_DIR="$KEYS_BASE/state"
KEYS_QUARANTINE_DIR="$KEYS_BASE/quarantine"
KEYS_SHARED="$KEYS_BASE/shared"
KEYS_SHARED_BARE="$KEYS_BASE/shared.git"
KEYS_LOCAL="$KEYS_BASE/local"
KEYS_LOCK="$KEYS_BASE/ledger.lock"
KEYS_TOOLS_BIN="${SUBYARD_KEYS_TOOLS_DIR:-$SUBYARD_HOME/tools}/bin"
KEYS_SOPS="${SUBYARD_SOPS_BIN:-$KEYS_TOOLS_BIN/sops}"
KEYS_AGE_KEYGEN="${SUBYARD_AGE_KEYGEN_BIN:-$KEYS_TOOLS_BIN/age-keygen}"
KEYS_SSH_KEYGEN="${SUBYARD_SSH_KEYGEN_BIN:-ssh-keygen}"
KEYS_GIT="${SUBYARD_GIT_BIN:-git}"
KEYS_JQ="${SUBYARD_JQ_BIN:-jq}"
KEYS_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KEYS_CONSUMER_ROOT="${SUBYARD_KEYS_CONSUMER_ROOT:-$KEYS_REPO_ROOT}"
declare -a KEYS_SECRET_TEMPS=()

keys_track_secret_temp() { KEYS_SECRET_TEMPS+=("$1"); }
keys_cleanup_secret_temps() {
  local path
  for path in "${KEYS_SECRET_TEMPS[@]}"; do [ -z "$path" ] || rm -f -- "$path"; done
}

keys_initialized() {
  [ -r "$KEYS_ID_JSON" ] && [ -r "$KEYS_AGE_ID" ] && [ -r "$KEYS_SIGN_KEY" ] \
    && [ -d "$KEYS_SHARED/.git" ] && [ -d "$KEYS_SHARED_BARE" ] && [ -d "$KEYS_LOCAL/.git" ]
}

keys_assert_store_boundary() {
  local root repo host_base
  root="$(realpath -m "$KEYS_ROOT")"; repo="$(realpath -m "$KEYS_REPO_ROOT")"; host_base="$(realpath -m "$HOST_BASE")"
  [ "$root" != / ] || die "SUBYARD_KEYS_ROOT cannot be the filesystem root"
  path_is_within "$root" "$repo" && die "SUBYARD_KEYS_ROOT must stay outside the Subyard checkout: $root"
  path_is_within "$root" "$host_base" && die "SUBYARD_KEYS_ROOT must stay outside HOST_BASE and every managed yard mount: $root"
  return 0
}

keys_require_commands() {
  command -v "$KEYS_JQ" >/dev/null 2>&1 || die "jq is required for encrypted credential ledgers"
  command -v "$KEYS_GIT" >/dev/null 2>&1 || die "git is required for encrypted credential ledgers"
  command -v "$KEYS_SSH_KEYGEN" >/dev/null 2>&1 || die "ssh-keygen is required to sign credential revisions"
  [ -x "$KEYS_SOPS" ] || die "pinned SOPS is missing — run: $(yard_cmd_hint) init"
  [ -x "$KEYS_AGE_KEYGEN" ] || die "pinned age is missing — run: $(yard_cmd_hint) init"
}

keys_require_initialized() {
  keys_assert_store_boundary
  keys_initialized || die "host credential ledger is not initialized — run: $(yard_cmd_hint) init"
  keys_require_commands
}

keys_actor_id() { "$KEYS_JQ" -r '.actorId' "$KEYS_ID_JSON"; }
keys_age_recipient() { "$KEYS_JQ" -r '.ageRecipient' "$KEYS_ID_JSON"; }
keys_signing_public() { "$KEYS_JQ" -r '.signingPublic' "$KEYS_ID_JSON"; }
keys_yard_id() { # <host-actor> <yard-context>
  local actor="$1" context="${2:-default}"
  case "$actor" in ''|*[!A-Za-z0-9._-]*) die "invalid host actor '$actor'" ;; esac
  case "$context" in ''|*[!a-z0-9_-]*|[!a-z0-9]*) die "invalid yard context '$context'" ;; esac
  printf '%s/%s\n' "$actor" "$context"
}
keys_current_yard_id() { keys_yard_id "$(keys_actor_id)" "$KEYS_CONTEXT"; }
keys_assignment_actor() { case "$1" in */*) printf '%s\n' "${1%%/*}" ;; *) return 1 ;; esac; }
keys_assignment_context() { case "$1" in */?*) printf '%s\n' "${1#*/}" ;; *) return 1 ;; esac; }

keys_random_hex() { od -An -N "${1:-16}" -tx1 /dev/urandom | tr -d ' \n'; }

keys_git() { # <repo> <git args...>
  local repo="$1"; shift
  "$KEYS_GIT" -C "$repo" -c core.hooksPath=/dev/null "$@"
}

keys_git_signed() { # <repo> <git args...>
  local repo="$1" actor; shift
  actor="$(keys_actor_id)"
  "$KEYS_GIT" -C "$repo" \
    -c core.hooksPath=/dev/null \
    -c user.name="$actor" -c user.email="$actor@subyard.invalid" \
    -c gpg.format=ssh -c user.signingkey="$KEYS_SIGN_KEY" \
    -c gpg.ssh.allowedSignersFile="$KEYS_ALLOWED_SIGNERS" \
    -c commit.gpgsign=true "$@"
}

keys_git_commit() { # <repo> <message>
  local repo="$1" message="$2"
  keys_git "$repo" add --all
  keys_git "$repo" diff --cached --quiet && return 0
  keys_git_signed "$repo" commit -S -m "$message" >/dev/null
  if [ "$repo" = "$KEYS_SHARED" ]; then
    keys_git "$KEYS_SHARED" push -q origin main
  fi
}

keys_refresh_shared_checkout() {
  keys_git "$KEYS_SHARED" fetch -q origin main
  keys_git "$KEYS_SHARED" merge --ff-only -q origin/main \
    || die "shared key checkout diverged from its local bare repository"
}

keys_allowed_signer_add() { # <actor> <ssh-public-line>
  local actor="$1" public="$2" key
  case "$actor" in ''|*[!A-Za-z0-9._-]*) die "invalid key actor id '$actor'" ;; esac
  key="$(printf '%s\n' "$public" | awk 'NF>=2 {print $1" "$2; exit}')"
  case "$key" in ssh-ed25519\ *) ;; *) die "peer '$actor' did not provide an ed25519 signing key" ;; esac
  install -d -m 700 "$KEYS_BASE"
  touch "$KEYS_ALLOWED_SIGNERS"; chmod 0600 "$KEYS_ALLOWED_SIGNERS"
  if ! awk -v a="$actor" '$1==a {found=1} END{exit !found}' "$KEYS_ALLOWED_SIGNERS"; then
    # The same dedicated key signs Git commits (namespace "git") and immutable revision files
    # (namespace "subyard-keys"). Do not constrain the line to only one namespace.
    printf '%s %s\n' "$actor" "$key" >> "$KEYS_ALLOWED_SIGNERS"
  fi
}

keys_init_repo() { # <path> [bare-origin]
  local repo="$1" origin="${2:-}"
  if [ -n "$origin" ]; then
    "$KEYS_GIT" init --bare --initial-branch=main "$origin" >/dev/null
    "$KEYS_GIT" clone -q "$origin" "$repo"
  else
    "$KEYS_GIT" init -q --initial-branch=main "$repo"
  fi
  install -d -m 700 "$repo/records"
  : > "$repo/.ledger"
  keys_git "$repo" add .ledger
  keys_git_signed "$repo" commit --allow-empty -S -m "Initialize encrypted credential ledger" >/dev/null
  [ -z "$origin" ] || keys_git "$repo" push -q -u origin main
}

keys_init_store() {
  keys_assert_store_boundary
  keys_require_commands
  if keys_initialized; then
    ok "host credential ledger already initialized at $KEYS_BASE"
    return 0
  fi
  umask 077
  install -d -m 700 "$KEYS_ROOT" "$KEYS_BASE" "$KEYS_ID_DIR" "$KEYS_PEERS_DIR" "$KEYS_STATE_DIR" \
    "$KEYS_QUARANTINE_DIR"
  chmod 0700 "$KEYS_ROOT" "$KEYS_BASE"
  [ ! -e "$KEYS_AGE_ID" ] || die "incomplete key identity already exists at $KEYS_AGE_ID"
  "$KEYS_AGE_KEYGEN" -o "$KEYS_AGE_ID" >/dev/null 2>&1
  chmod 0600 "$KEYS_AGE_ID"
  "$KEYS_SSH_KEYGEN" -q -t ed25519 -N '' -C "subyard-credentials-host" -f "$KEYS_SIGN_KEY"
  chmod 0600 "$KEYS_SIGN_KEY"; chmod 0644 "$KEYS_SIGN_PUB"
  local public actor age_recipient
  public="$(cat "$KEYS_SIGN_PUB")"
  actor="host-$(printf '%s' "$public" | sha256sum | cut -c1-16)"
  age_recipient="$("$KEYS_AGE_KEYGEN" -y "$KEYS_AGE_ID")"
  "$KEYS_JQ" -n -S \
    --argjson schemaVersion "$KEYS_SCHEMA_VERSION" --arg actorId "$actor" \
    --arg identityScope host --arg ageRecipient "$age_recipient" \
    --arg signingPublic "$public" \
    '{schemaVersion:$schemaVersion,actorId:$actorId,identityScope:$identityScope,
      ageRecipient:$ageRecipient,signingPublic:$signingPublic}' > "$KEYS_ID_JSON"
  chmod 0600 "$KEYS_ID_JSON"
  : > "$KEYS_ALLOWED_SIGNERS"; chmod 0600 "$KEYS_ALLOWED_SIGNERS"
  keys_allowed_signer_add "$actor" "$public"
  keys_init_repo "$KEYS_SHARED" "$KEYS_SHARED_BARE"
  keys_init_repo "$KEYS_LOCAL"
  printf '0\n' > "$KEYS_STATE_DIR/counter"; chmod 0600 "$KEYS_STATE_DIR/counter"
  ok "initialized host-only credential ledger at $KEYS_BASE"
}

keys_lock_acquire() {
  command -v flock >/dev/null 2>&1 || die "flock is required for credential ledger updates"
  install -d -m 700 "$KEYS_BASE"
  exec 9>"$KEYS_LOCK"
  flock 9 || die "could not lock host credential ledger"
}

keys_next_counter() {
  local current=0
  [ -r "$KEYS_STATE_DIR/counter" ] && read -r current < "$KEYS_STATE_DIR/counter"
  case "$current" in ''|*[!0-9]*) die "invalid key actor counter" ;; esac
  current=$((current + 1))
  printf '%s\n' "$current" > "$KEYS_STATE_DIR/counter.tmp"
  mv -f "$KEYS_STATE_DIR/counter.tmp" "$KEYS_STATE_DIR/counter"
  printf '%s\n' "$current"
}

keys_peer_file() { # <peer-name>
  case "$1" in ''|*[!a-z0-9_-]*) die "invalid peer name '$1'" ;; esac
  printf '%s/%s.json\n' "$KEYS_PEERS_DIR" "$1"
}

keys_peer_names() {
  local f
  for f in "$KEYS_PEERS_DIR"/*.json; do
    [ -e "$f" ] || continue
    basename "$f" .json
  done
}

keys_peer_by_actor() { # <actor> -> peer json path
  local actor="$1" f
  for f in "$KEYS_PEERS_DIR"/*.json; do
    [ -e "$f" ] || continue
    [ "$("$KEYS_JQ" -r '.actorId' "$f")" = "$actor" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

keys_recipient_for_actor() { # <actor>
  local actor="$1" peer
  if [ "$actor" = "$(keys_actor_id)" ]; then keys_age_recipient; return 0; fi
  peer="$(keys_peer_by_actor "$actor")" || return 1
  "$KEYS_JQ" -r '.ageRecipient' "$peer"
}

keys_all_recipient_actors_json() {
  {
    keys_actor_id
    local f
    for f in "$KEYS_PEERS_DIR"/*.json; do
      [ -e "$f" ] || continue
      "$KEYS_JQ" -r 'select(.trusted == true) | .actorId' "$f"
    done
  } | "$KEYS_JQ" -Rsc 'split("\n") | map(select(length>0)) | unique | sort'
}

keys_age_csv_for_actors() { # <actors-json>
  local json="$1" actor recipient csv=''
  while IFS= read -r actor; do
    [ -n "$actor" ] || continue
    recipient="$(keys_recipient_for_actor "$actor")" \
      || die "no age recipient enrolled for actor '$actor'"
    csv="${csv:+$csv,}$recipient"
  done < <(printf '%s' "$json" | "$KEYS_JQ" -r '.[]')
  [ -n "$csv" ] || die "a revision must have at least one age recipient"
  printf '%s\n' "$csv"
}

keys_sign_record() { # <record>
  local record="$1"
  rm -f "$record.sig"
  "$KEYS_SSH_KEYGEN" -Y sign -q -f "$KEYS_SIGN_KEY" -n subyard-keys "$record" >/dev/null
  [ -s "$record.sig" ] || die "could not sign credential revision"
}

keys_verify_record() { # <record>
  local record="$1" actor revision credential expected_rel counter expected_prefix actual_recipients expected_recipients recipient
  [ -s "$record.sig" ] || return 1
  "$KEYS_JQ" -e --argjson schema "$KEYS_SCHEMA_VERSION" '
    ([keys[]] - ["schemaVersion","credentialId","revisionId","label","kind","zone","scope",
      "consumer","syncable","exclusive","recipientActors","authorityHost","assignedYard",
      "assignmentEpoch","actorId","actorCounter","parents","timestamp","state","payload","sops"] | length)==0 and
    .schemaVersion == $schema and (.credentialId|test("^cred-[0-9a-f]{32}$")) and
    (.revisionId|type)=="string" and (.label|type)=="string" and (.label|length)>0 and (.label|length)<=128 and
    (.kind|test("^[A-Za-z0-9._-]+$")) and (.zone|test("^[A-Za-z0-9._-]+$")) and .zone!="." and .zone!=".." and
    .scope=="staging" and (.consumer=="none" or .consumer=="staging-env" or .consumer=="qa-secrets" or .consumer=="qa-pool") and
    (.actorId|test("^[A-Za-z0-9._-]+$")) and (.actorCounter|type)=="number" and
    (.actorCounter|floor)==.actorCounter and .actorCounter>0 and
    (.parents|type)=="array" and all(.parents[]; type=="string") and (.parents|length)==(.parents|unique|length) and
    (.recipientActors|type)=="array" and (.recipientActors|length)>0 and all(.recipientActors[]; type=="string") and
    (.recipientActors|length)==(.recipientActors|unique|length) and
    (.state=="active" or .state=="revoked" or .state=="tombstone") and
    (.syncable|type)=="boolean" and (.exclusive|type)=="boolean" and
    (.authorityHost|type)=="string" and (.authorityHost=="" or (.authorityHost|test("^[A-Za-z0-9._-]+$"))) and
    (.assignedYard|type)=="string" and (.assignedYard=="" or (.assignedYard|test("^[A-Za-z0-9._-]+/[a-z0-9][a-z0-9_-]*$"))) and
    (.assignmentEpoch|type)=="number" and (.assignmentEpoch|floor)==.assignmentEpoch and .assignmentEpoch>=0 and
    (.timestamp|type)=="string" and (.payload|type)=="string" and (.sops|type)=="object"
  ' "$record" >/dev/null 2>&1 || return 1
  actor="$("$KEYS_JQ" -r '.actorId' "$record")"
  revision="$("$KEYS_JQ" -r '.revisionId' "$record")"
  credential="$("$KEYS_JQ" -r '.credentialId' "$record")"
  counter="$("$KEYS_JQ" -r '.actorCounter' "$record")"
  case "$credential/$revision/$actor" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
  expected_prefix="$actor-$(printf '%012d' "$counter")-"
  case "$revision" in "$expected_prefix"????????) ;; *) return 1 ;; esac
  expected_rel="records/$credential/$revision.json"
  case "$record" in */"$expected_rel") ;; *) return 1 ;; esac
  [ "$("$KEYS_JQ" -r '.recipientActors | length' "$record")" \
    = "$("$KEYS_JQ" -r '.recipientActors | unique | length' "$record")" ] || return 1
  expected_recipients=''
  while IFS= read -r recipient; do
    recipient="$(keys_recipient_for_actor "$recipient")" || return 1
    expected_recipients="${expected_recipients}${recipient}"$'\n'
  done < <("$KEYS_JQ" -r '.recipientActors[]' "$record")
  expected_recipients="$(printf '%s' "$expected_recipients" | sed '/^$/d' | sort -u)"
  actual_recipients="$("$KEYS_JQ" -r '.sops.age[].recipient' "$record" 2>/dev/null | sort -u)"
  [ -n "$actual_recipients" ] && [ "$actual_recipients" = "$expected_recipients" ] || return 1
  "$KEYS_SSH_KEYGEN" -Y verify -q -f "$KEYS_ALLOWED_SIGNERS" -I "$actor" \
    -n subyard-keys -s "$record.sig" < "$record" >/dev/null 2>&1 || return 1
  return 0
}

keys_decrypt_payload() { # <record> <output-file>
  local record="$1" output="$2" tmp
  tmp="$(mktemp)"; chmod 0600 "$tmp"
  keys_track_secret_temp "$tmp"; keys_track_secret_temp "$output"
  if ! SOPS_AGE_KEY_FILE="$KEYS_AGE_ID" "$KEYS_SOPS" decrypt \
      --input-type json --output-type json "$record" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  "$KEYS_JQ" -er '.payload' "$tmp" | base64 -d > "$output" || { rm -f "$tmp" "$output"; return 1; }
  chmod 0600 "$output"; rm -f "$tmp"
}

keys_record_files() { # <repo> [credential-id]
  local repo="$1" credential="${2:-}"
  if [ -n "$credential" ]; then
    [ -d "$repo/records/$credential" ] || return 0
    find "$repo/records/$credential" -maxdepth 1 -type f -name '*.json' -print | sort
  else
    find "$repo/records" -mindepth 2 -maxdepth 2 -type f -name '*.json' -print | sort
  fi
}

keys_heads_json() { # <repo> <credential-id>
  local repo="$1" credential="$2" files=()
  mapfile -t files < <(keys_record_files "$repo" "$credential")
  [ "${#files[@]}" -gt 0 ] || { printf '[]\n'; return 0; }
  "$KEYS_JQ" -s '
    (map(.parents[]) | unique) as $parents |
    map(select(.revisionId as $id | ($parents | index($id) | not))) |
    sort_by(.actorId,.actorCounter,.revisionId)
  ' "${files[@]}"
}

keys_record_path() { # <repo> <credential> <revision>
  printf '%s/records/%s/%s.json\n' "$1" "$2" "$3"
}

keys_parent_json_from_heads() { # <heads-json>
  printf '%s' "$1" | "$KEYS_JQ" -c '[.[].revisionId] | unique | sort'
}

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

keys_repo_credentials() { # <repo>
  local d
  for d in "$1"/records/*; do [ -d "$d" ] && basename "$d"; done | sort -u
}

keys_metadata_compatible() { # <heads-json>
  printf '%s' "$1" | "$KEYS_JQ" -e '
    (([.[].label] | unique | length) == 1) and (([.[].kind] | unique | length) == 1) and
    (([.[].zone] | unique | length) == 1) and (([.[].consumer] | unique | length) == 1) and
    (([.[].authorityHost] | unique | length) == 1) and (([.[].assignedYard] | unique | length) == 1) and
    (([.[].assignmentEpoch] | unique | length) == 1)
  ' >/dev/null
}

keys_recipient_intersection() { # <heads-json>
  printf '%s' "$1" | "$KEYS_JQ" -c '
    if length==0 then [] else
      .[0].recipientActors as $first |
      [$first[] as $actor | select(all(.[]; (.recipientActors | index($actor)) != null)) | $actor] | unique | sort
    end
  '
}

keys_reconcile_credential() { # <repo> <credential>; returns 0 safe/single, 2 unsafe conflict
  local repo="$1" cred="$2" heads count states terminal_state first parents recipients exclusive payload tmp hash first_hash=''
  heads="$(keys_heads_json "$repo" "$cred")"; count="$(printf '%s' "$heads" | "$KEYS_JQ" 'length')"
  [ "$count" -gt 1 ] || return 0
  first="$(printf '%s' "$heads" | "$KEYS_JQ" '.[0]')"
  parents="$(keys_parent_json_from_heads "$heads")"
  recipients="$(keys_recipient_intersection "$heads")"
  [ "$(printf '%s' "$recipients" | "$KEYS_JQ" 'length')" -gt 0 ] || return 2
  states="$(printf '%s' "$heads" | "$KEYS_JQ" -r '[.[].state] | unique | join(" ")')"
  exclusive="$(printf '%s' "$heads" | "$KEYS_JQ" 'any(.[]; .exclusive == true)')"
  tmp="$(mktemp)"; chmod 0600 "$tmp"
  if [[ " $states " == *" revoked "* || " $states " == *" tombstone "* ]]; then
    if [[ " $states " == *" tombstone "* ]]; then terminal_state=tombstone; else terminal_state=revoked; fi
    : > "$tmp"
    keys_write_revision "$repo" "$cred" \
      "$(printf '%s' "$first" | "$KEYS_JQ" -r '.label')" \
      "$(printf '%s' "$first" | "$KEYS_JQ" -r '.kind')" \
      "$(printf '%s' "$first" | "$KEYS_JQ" -r '.zone')" \
      "$(printf '%s' "$first" | "$KEYS_JQ" -r '.consumer')" \
      "$(printf '%s' "$first" | "$KEYS_JQ" -r '.syncable')" "$exclusive" "$terminal_state" "$parents" "$tmp" "$recipients" \
      "$(printf '%s' "$first" | "$KEYS_JQ" -r '.authorityHost')" \
      "$(printf '%s' "$first" | "$KEYS_JQ" -r '.assignedYard')" \
      "$(printf '%s' "$first" | "$KEYS_JQ" -r '.assignmentEpoch')" >/dev/null
    rm -f "$tmp"; return 0
  fi
  keys_metadata_compatible "$heads" || { rm -f "$tmp"; return 2; }
  while IFS= read -r revision; do
    payload="$(keys_record_path "$repo" "$cred" "$revision")"
    keys_decrypt_payload "$payload" "$tmp" || { rm -f "$tmp"; return 2; }
    hash="$(sha256sum "$tmp" | cut -d' ' -f1)"
    [ -z "$first_hash" ] && first_hash="$hash"
    [ "$hash" = "$first_hash" ] || { rm -f "$tmp"; return 2; }
  done < <(printf '%s' "$heads" | "$KEYS_JQ" -r '.[].revisionId')
  keys_write_revision "$repo" "$cred" \
    "$(printf '%s' "$first" | "$KEYS_JQ" -r '.label')" \
    "$(printf '%s' "$first" | "$KEYS_JQ" -r '.kind')" \
    "$(printf '%s' "$first" | "$KEYS_JQ" -r '.zone')" \
    "$(printf '%s' "$first" | "$KEYS_JQ" -r '.consumer')" \
    "$(printf '%s' "$first" | "$KEYS_JQ" -r '.syncable')" "$exclusive" active "$parents" "$tmp" "$recipients" \
    "$(printf '%s' "$first" | "$KEYS_JQ" -r '.authorityHost')" \
    "$(printf '%s' "$first" | "$KEYS_JQ" -r '.assignedYard')" \
    "$(printf '%s' "$first" | "$KEYS_JQ" -r '.assignmentEpoch')" >/dev/null
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
  local exclusive assigned authority peer state_file last now
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
    assigned="$(printf '%s' "$head" | "$KEYS_JQ" -r '.assignedYard')"
    if [ "$assigned" != "$(keys_current_yard_id)" ]; then
      [ ! -e "$dest" ] || rm -f -- "$dest"
      return 0
    fi
    authority="$(printf '%s' "$head" | "$KEYS_JQ" -r '.authorityHost')"
    if [ "$authority" != "$actor" ]; then
      peer="$(keys_peer_by_actor "$authority")" || { [ "$automatic" = 1 ] || warn "$cred has no trusted authority"; return 1; }
      state_file="$(keys_sync_state_file "$(basename "$peer" .json)")"; last=0; now="$(date +%s)"
      [ -r "$state_file" ] && last="$("$KEYS_JQ" -r '.lastSuccess // 0' "$state_file")"
      [ "$last" -gt 0 ] && [ $((now - last)) -le "${SUBYARD_KEYS_AUTHORITY_MAX_AGE:-3600}" ] \
        || { [ "$automatic" = 1 ] || warn "$cred has no fresh authority exchange"; return 1; }
    fi
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

keys_peer_target_resolve() { # <registry-name>; sets KEYS_TARGET_*
  local peer="$1" env_file type
  case "$peer" in ''|*[!a-z0-9_-]*) die "invalid peer context '$peer'" ;; esac
  [ "$peer" != "$KEYS_CONTEXT" ] || die "cannot enroll the current yard as its own credential peer"
  KEYS_TARGET_TRANSPORT=local; KEYS_TARGET_DEST=''; KEYS_TARGET_REMOTE_YARD=''
  if [ "$peer" = default ]; then return 0; fi
  env_file="$(yard_env_file "$peer")" || die "unknown yard context '$peer'"
  type="$(yard_env_val "$env_file" YARD_TYPE)"; type="${type:-local}"
  if [ "$type" = remote ]; then
    KEYS_TARGET_TRANSPORT=ssh
    KEYS_TARGET_DEST="$(yard_env_val "$env_file" REMOTE_DEST)"
    KEYS_TARGET_REMOTE_YARD="$(yard_env_val "$env_file" REMOTE_YARD)"
    [ -n "$KEYS_TARGET_DEST" ] || die "remote yard '$peer' has no REMOTE_DEST"
  fi
}

keys_build_remote_command() { # <remote-yard> <args...>
  local remote_yard="$1" command='yard' arg; shift
  [ -z "$remote_yard" ] || command="$command -Y $(printf '%q' "$remote_yard")"
  for arg in "$@"; do command="$command $(printf '%q' "$arg")"; done
  printf '%s\n' "$command"
}

keys_target_exec() { # <registry-peer> <args...>; stdin is forwarded
  local peer="$1" command; shift
  keys_peer_target_resolve "$peer"
  if [ "$KEYS_TARGET_TRANSPORT" = ssh ]; then
    command="$(keys_build_remote_command "$KEYS_TARGET_REMOTE_YARD" "$@")"
    ssh -o BatchMode=yes -o ConnectTimeout="${SUBYARD_KEYS_SSH_TIMEOUT:-8}" \
      "$KEYS_TARGET_DEST" -- bash -lc "$(printf '%q' "$command")"
  elif [ "$peer" = default ]; then
    env -u SUBYARD_YARD "$KEYS_REPO_ROOT/bin/yard" "$@"
  else
    "$KEYS_REPO_ROOT/bin/yard" -Y "$peer" "$@"
  fi
}

keys_enrolled_exec() { # <peer> <args...>
  local peer="$1" file transport dest remote_yard command; shift
  file="$(keys_peer_file "$peer")"; [ -r "$file" ] || die "credential peer '$peer' is not enrolled"
  transport="$("$KEYS_JQ" -r '.transport' "$file")"
  case "$transport" in
    ssh)
      dest="$("$KEYS_JQ" -r '.dest' "$file")"; remote_yard="$("$KEYS_JQ" -r '.remoteYard' "$file")"
      command="$(keys_build_remote_command "$remote_yard" "$@")"
      ssh -o BatchMode=yes -o ConnectTimeout="${SUBYARD_KEYS_SSH_TIMEOUT:-8}" \
        "$dest" -- bash -lc "$(printf '%q' "$command")" ;;
    local)
      if [ "$peer" = default ]; then env -u SUBYARD_YARD "$KEYS_REPO_ROOT/bin/yard" "$@"
      else "$KEYS_REPO_ROOT/bin/yard" -Y "$peer" "$@"; fi ;;
    inbound) die "peer '$peer' has no reverse transport; sync it from the controller that enrolled it" ;;
    *) die "peer '$peer' has invalid transport '$transport'" ;;
  esac
}

keys_enrolled_exec_context() { # <peer> <yard-context> <args...>
  local peer="$1" context="${2:-default}" file transport dest command; shift 2
  file="$(keys_peer_file "$peer")"; [ -r "$file" ] || die "credential peer '$peer' is not enrolled"
  transport="$("$KEYS_JQ" -r '.transport' "$file")"
  case "$transport" in
    ssh)
      dest="$("$KEYS_JQ" -r '.dest' "$file")"
      [ "$context" = default ] && context=''
      command="$(keys_build_remote_command "$context" "$@")"
      ssh -o BatchMode=yes -o ConnectTimeout="${SUBYARD_KEYS_SSH_TIMEOUT:-8}" \
        "$dest" -- bash -lc "$(printf '%q' "$command")" ;;
    local)
      if [ "$context" = default ]; then env -u SUBYARD_YARD "$KEYS_REPO_ROOT/bin/yard" "$@"
      else "$KEYS_REPO_ROOT/bin/yard" -Y "$context" "$@"; fi ;;
    inbound) die "peer '$peer' has no reverse transport; sync it from the controller that enrolled it" ;;
    *) die "peer '$peer' has invalid transport '$transport'" ;;
  esac
}

keys_store_peer() { # name identity-json transport dest remote-yard manual-only
  local name="$1" identity="$2" transport="$3" dest="$4" remote_yard="$5" manual="$6"
  local file requested_file actor_file='' existing_file='' actor age_recipient signing_public existing existing_transport
  actor="$(printf '%s' "$identity" | "$KEYS_JQ" -er --argjson schema "$KEYS_SCHEMA_VERSION" \
    'select(.schemaVersion==$schema and .identityScope=="host") | .actorId')" \
    || die "peer identity has an unsupported schema or scope"
  age_recipient="$(printf '%s' "$identity" | "$KEYS_JQ" -er '.ageRecipient | select(startswith("age1"))')" \
    || die "peer identity has an invalid age recipient"
  signing_public="$(printf '%s' "$identity" | "$KEYS_JQ" -er '.signingPublic | select(startswith("ssh-ed25519 "))')" \
    || die "peer identity has an invalid signing key"
  requested_file="$(keys_peer_file "$name")"; file="$requested_file"
  if [ -r "$requested_file" ]; then
    existing="$("$KEYS_JQ" -r '.actorId' "$requested_file")"
    [ "$existing" = "$actor" ] || die "peer '$name' changed identity ($existing -> $actor); remove/re-enroll explicitly"
    existing_file="$requested_file"
  else
    actor_file="$(keys_peer_by_actor "$actor" || true)"
    [ -z "$actor_file" ] || existing_file="$actor_file"
  fi
  if [ -n "$existing_file" ]; then
    # A reciprocal inbound handshake proves cryptographic trust, but carries no return route.
    # Never let it erase a local/SSH route (or its operator-selected sync policy) that this side
    # already knows. Match by actor, not the remote-provided name: the local registry may use a
    # different alias for the same host. An explicit outbound enrollment owns the local name.
    existing_transport="$("$KEYS_JQ" -r '.transport // ""' "$existing_file")"
    if [ "$transport" = inbound ]; then
      file="$existing_file"
      name="$("$KEYS_JQ" -r '.name' "$existing_file")"
      case "$existing_transport" in
        local|ssh)
          transport="$existing_transport"
          dest="$("$KEYS_JQ" -r '.dest // ""' "$existing_file")"
          remote_yard="$("$KEYS_JQ" -r '.remoteYard // ""' "$existing_file")"
          manual="$("$KEYS_JQ" -r '.manualOnly // false' "$existing_file")" ;;
      esac
    fi
  fi
  "$KEYS_JQ" -n -S --argjson schemaVersion "$KEYS_SCHEMA_VERSION" --arg name "$name" \
    --arg actorId "$actor" --arg ageRecipient "$age_recipient" --arg signingPublic "$signing_public" \
    --arg transport "$transport" --arg dest "$dest" --arg remoteYard "$remote_yard" \
    --argjson manualOnly "$manual" \
    '{schemaVersion:$schemaVersion,name:$name,actorId:$actorId,ageRecipient:$ageRecipient,
      signingPublic:$signingPublic,transport:$transport,dest:$dest,remoteYard:$remoteYard,
      manualOnly:$manualOnly,trusted:true}' > "$file.tmp"
  chmod 0600 "$file.tmp"; mv -f "$file.tmp" "$file"
  [ -z "$existing_file" ] || [ "$existing_file" = "$file" ] || rm -f -- "$existing_file"
  keys_allowed_signer_add "$actor" "$signing_public"
}

keys_peer_role() { # <peer-json>; active has an outbound route, passive only accepts inbound sync
  case "$("$KEYS_JQ" -r '.transport // ""' "$1")" in
    local|ssh) printf 'active\n' ;;
    inbound) printf 'passive\n' ;;
    *) return 1 ;;
  esac
}

keys_peer_yard_id() { # <peer-json>; outbound route's host/context assignment
  local file="$1" actor transport context
  actor="$("$KEYS_JQ" -r '.actorId' "$file")"; transport="$("$KEYS_JQ" -r '.transport' "$file")"
  case "$transport" in
    local) context="$("$KEYS_JQ" -r '.name' "$file")" ;;
    ssh) context="$("$KEYS_JQ" -r '.remoteYard // ""' "$file")"; context="${context:-default}" ;;
    *) return 1 ;;
  esac
  keys_yard_id "$actor" "$context"
}

keys_allowed_signers_rebuild() {
  local actor public f
  : > "$KEYS_ALLOWED_SIGNERS"; chmod 0600 "$KEYS_ALLOWED_SIGNERS"
  keys_allowed_signer_add "$(keys_actor_id)" "$(keys_signing_public)"
  for f in "$KEYS_PEERS_DIR"/*.json; do
    [ -e "$f" ] || continue
    actor="$("$KEYS_JQ" -r '.actorId' "$f")"; public="$("$KEYS_JQ" -r '.signingPublic' "$f")"
    keys_allowed_signer_add "$actor" "$public"
  done
}

keys_identity_fingerprint() { # <identity-json>
  local identity="$1" sign
  sign="$(printf '%s' "$identity" | "$KEYS_JQ" -r '.signingPublic')"
  printf 'actor=%s age=%s signing=%s\n' \
    "$(printf '%s' "$identity" | "$KEYS_JQ" -r '.actorId')" \
    "$(printf '%s' "$identity" | "$KEYS_JQ" -r '.ageRecipient')" \
    "$(printf '%s\n' "$sign" | "$KEYS_SSH_KEYGEN" -lf - -E sha256 | awk '{print $2}')"
}

keys_trust_peer() { # <peer> <manual-only:true|false>
  local peer="$1" manual="$2" identity local_identity actor transport dest remote_yard
  keys_require_initialized
  identity="$(keys_target_exec "$peer" _keys-exchange identity)" \
    || die "peer '$peer' has no initialized credential ledger; initialize it on its owner host first"
  actor="$(printf '%s' "$identity" | "$KEYS_JQ" -er '.actorId')" || die "peer '$peer' returned invalid identity data"
  [ "$actor" != "$(keys_actor_id)" ] || die "peer '$peer' resolves to this same key identity"
  keys_peer_target_resolve "$peer"; transport="$KEYS_TARGET_TRANSPORT"; dest="$KEYS_TARGET_DEST"; remote_yard="$KEYS_TARGET_REMOTE_YARD"
  announce "Trust credential peer '$peer'" \
    "$(keys_identity_fingerprint "$identity")" \
    "Exchange this host's public age recipient and revision-signing key with the peer." \
    "$([ "$manual" = true ] && printf 'Keep synchronization manual.' || printf 'Enable unattended encrypted synchronization (default).')" \
    "Re-encrypt current shared heads for the newly authorized recipient; plaintext is never transported."
  proceed_or_die
  keys_lock_acquire
  keys_store_peer "$peer" "$identity" "$transport" "$dest" "$remote_yard" "$manual"
  local_identity="$(cat "$KEYS_ID_JSON")"
  if ! printf '%s\n' "$local_identity" | keys_target_exec "$peer" _keys-exchange trust-import "$KEYS_CONTEXT"; then
    die "peer '$peer' did not accept reciprocal trust; local enrollment is kept for an idempotent retry"
  fi
  keys_rekey_shared_for_actor "$actor" add
  keys_sync_peer "$peer"
  ok "trusted credential peer '$peer' (auto-sync=$([ "$manual" = true ] && echo off || echo on))"
}

keys_untrust_peer() { # <peer>
  local peer="$1" file actor
  keys_require_initialized; file="$(keys_peer_file "$peer")"; [ -r "$file" ] || die "credential peer '$peer' is not enrolled"
  actor="$("$KEYS_JQ" -r '.actorId' "$file")"
  announce "Remove credential peer '$peer'" \
    "Publish successor revisions that no longer encrypt current heads to $actor." \
    "Remove its signing trust and automatic synchronization." \
    "This cannot erase plaintext/ciphertext already received: rotate upstream credentials after removal."
  proceed_or_die
  keys_lock_acquire
  keys_rekey_shared_for_actor "$actor" remove
  keys_enrolled_exec "$peer" _keys-exchange untrust-import "$(keys_actor_id)" >/dev/null 2>&1 || \
    warn "peer '$peer' was unreachable; its reciprocal trust could not be removed"
  rm -f "$file" "$(keys_sync_state_file "$peer")"
  keys_allowed_signers_rebuild
  ok "removed credential peer '$peer'; rotate any credential it previously received"
}

keys_verify_remote_commits() { # <ref>
  local ref="$1" commit
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    keys_git "$KEYS_SHARED" -c gpg.ssh.allowedSignersFile="$KEYS_ALLOWED_SIGNERS" \
      verify-commit "$commit" >/dev/null 2>&1 || return 1
  done < <(keys_git "$KEYS_SHARED" rev-list "$ref" --not main)
}

keys_verify_append_only_commits() { # <ref>
  local ref="$1" commit changes
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    changes="$(keys_git "$KEYS_SHARED" diff-tree -m --root --no-commit-id --name-status -r "$commit" -- records)"
    while IFS=$'\t' read -r status _; do
      [ -z "$status" ] || [ "$status" = A ] || return 1
    done <<< "$changes"
  done < <(keys_git "$KEYS_SHARED" rev-list --reverse "$ref" --not main)
}

keys_peer_git_url() { # <peer>
  local peer="$1" file transport path dest
  file="$(keys_peer_file "$peer")"; transport="$("$KEYS_JQ" -r '.transport' "$file")"
  path="$(keys_enrolled_exec "$peer" _keys-exchange bare-path)" || return 1
  case "$path" in /*) ;; *) return 1 ;; esac
  case "$path" in *[!A-Za-z0-9_./-]*) return 1 ;; esac
  if [ "$transport" = ssh ]; then
    dest="$("$KEYS_JQ" -r '.dest' "$file")"; printf '%s:%s\n' "$dest" "$path"
  else
    printf '%s\n' "$path"
  fi
}

keys_validate_fetched_ref() { # <peer> <ref>
  local peer="$1" ref="$2" state last tmp deleted
  state="$(keys_sync_state_file "$peer")"; last=''
  [ -r "$state" ] && last="$("$KEYS_JQ" -r '.lastHead // ""' "$state")"
  if [ -n "$last" ]; then
    keys_git "$KEYS_SHARED" cat-file -e "$last^{commit}" 2>/dev/null \
      || die "recorded peer head $last is missing from the local ledger"
    keys_git "$KEYS_SHARED" merge-base --is-ancestor "$last" "$ref" \
      || die "peer '$peer' rewrote or removed previously observed Git history"
    deleted="$(keys_git "$KEYS_SHARED" diff --diff-filter=D --name-only "$last..$ref" -- records)"
    [ -z "$deleted" ] || die "peer '$peer' deleted immutable revision objects"
  fi
  keys_verify_remote_commits "$ref" || die "peer '$peer' has a commit without an allowed SSH signature"
  keys_verify_append_only_commits "$ref" || die "peer '$peer' modified or deleted an immutable revision object"
  tmp="$(mktemp -d)"; install -d -m 700 "$tmp/records"
  if ! keys_git "$KEYS_SHARED" archive "$ref" | tar -x -C "$tmp"; then
    rm -rf "$tmp"; die "peer '$peer' ledger archive could not be read"
  fi
  if ! keys_verify_tree "$tmp"; then
    rm -rf "$tmp"; die "peer '$peer' sent an invalid revision; ciphertext was quarantined"
  fi
  rm -rf "$tmp"
}

keys_merge_fetched_ref() { # <ref>
  local ref="$1" conflicts=''
  if keys_git "$KEYS_SHARED" merge-base main "$ref" >/dev/null 2>&1; then
    keys_git_signed "$KEYS_SHARED" merge -q -S --no-edit "$ref" \
      || { keys_git "$KEYS_SHARED" merge --abort >/dev/null 2>&1 || true; die "append-only ledger merge conflicted"; }
  else
    keys_git_signed "$KEYS_SHARED" merge -q -S --no-edit --allow-unrelated-histories "$ref" \
      || { keys_git "$KEYS_SHARED" merge --abort >/dev/null 2>&1 || true; die "unrelated ledger merge conflicted"; }
  fi
  conflicts="$(keys_reconcile_repo "$KEYS_SHARED" 2>/dev/null)" || true
  keys_git "$KEYS_SHARED" push -q origin main
  [ -z "$conflicts" ] || warn "unresolved credential heads after sync: $(tr '\n' ' ' <<<"$conflicts")"
}

keys_sync_peer_once() { # <peer>
  local peer="$1" file url ref attempt head transport GIT_SSH_COMMAND=''
  file="$(keys_peer_file "$peer")"; [ -r "$file" ] || die "credential peer '$peer' is not enrolled"
  transport="$("$KEYS_JQ" -r '.transport' "$file")"
  if [ "$transport" = ssh ]; then
    GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=${SUBYARD_KEYS_SSH_TIMEOUT:-8}"
    export GIT_SSH_COMMAND
  fi
  url="$(keys_peer_git_url "$peer")" || die "peer '$peer' did not expose a safe ledger path"
  ref="refs/remotes/keys/$peer"
  keys_refresh_shared_checkout
  for attempt in 1 2 3; do
    keys_git "$KEYS_SHARED" fetch -q --no-tags "$url" "+refs/heads/main:$ref"
    keys_validate_fetched_ref "$peer" "$ref"
    keys_merge_fetched_ref "$ref"
    if keys_git "$KEYS_SHARED" push -q "$url" main:main; then
      keys_enrolled_exec "$peer" _keys-exchange refresh "$(keys_actor_id)" >/dev/null
      keys_materialize_all '' 1 || true
      head="$(keys_git "$KEYS_SHARED" rev-parse main)"
      printf '%s\n' "$head"
      return 0
    fi
    warn "peer '$peer' advanced during sync; retrying ($attempt/3)"
  done
  die "peer '$peer' kept advancing; sync did not converge after 3 attempts"
}

keys_sync_peer() { # <peer>
  local peer="$1" output head message
  if output="$(keys_sync_peer_once "$peer" 2>&1)"; then
    head="${output##*$'\n'}"; keys_state_write "$peer" 1 '' "$head"
    ok "credential ledger synchronized with '$peer'"
    return 0
  fi
  message="$(printf '%s' "$output" | tail -n1 | tr '\n' ' ' | cut -c1-300)"
  keys_state_write "$peer" 0 "$message" ''
  warn "credential sync with '$peer' failed: $message"
  return 1
}

keys_sync_all() { # [if-due:0|1]
  local if_due="${1:-0}" peer file rc=0 manual role
  keys_require_initialized; keys_lock_acquire
  while IFS= read -r peer; do
    [ -n "$peer" ] || continue
    file="$(keys_peer_file "$peer")"; role="$(keys_peer_role "$file")" \
      || die "peer '$peer' has an invalid transport role"
    [ "$role" = active ] || continue
    manual="$("$KEYS_JQ" -r '.manualOnly // false' "$file")"
    [ "$manual" != true ] || continue
    [ "$if_due" = 0 ] || keys_state_due "$peer" "${SUBYARD_KEYS_IF_DUE_SECONDS:-3600}" || continue
    keys_sync_peer "$peer" || rc=1
  done < <(keys_peer_names)
  return "$rc"
}

keys_exchange_refresh() {
  keys_require_initialized; keys_lock_acquire
  keys_refresh_shared_checkout
  keys_reconcile_repo "$KEYS_SHARED" >/dev/null 2>&1 || true
  keys_git "$KEYS_SHARED" push -q origin main
  keys_materialize_all '' 1 || true
}
