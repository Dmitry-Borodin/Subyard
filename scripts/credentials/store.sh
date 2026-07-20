#!/usr/bin/env bash
# store.sh — protected ledger paths, identity, Git-backed stores and record I/O.
# shellcheck disable=SC2034 # KEYS_CONSUMER_ROOT is a materialization-adapter input.

[ -n "${SUBYARD_CREDENTIAL_STORE_SOURCED:-}" ] && return 0
SUBYARD_CREDENTIAL_STORE_SOURCED=1

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


# JSON is an injected adapter for domain modules; they never reference the jq binary/config global.
credential_json() { "$KEYS_JQ" "$@"; }

keys_record_files() { # <repo> [credential-id]
  local repo="$1" credential="${2:-}"
  if [ -n "$credential" ]; then
    [ -d "$repo/records/$credential" ] || return 0
    find "$repo/records/$credential" -maxdepth 1 -type f -name '*.json' -print | sort
  else
    find "$repo/records" -mindepth 2 -maxdepth 2 -type f -name '*.json' -print | sort
  fi
}

keys_record_path() { # <repo> <credential> <revision>
  printf '%s/records/%s/%s.json\n' "$1" "$2" "$3"
}

keys_repo_credentials() { # <repo>
  local d
  for d in "$1"/records/*; do [ -d "$d" ] && basename "$d"; done | sort -u
}
