#!/usr/bin/env bash
# sync.sh — signed append-only Git exchange and synchronization orchestration.

[ -n "${SUBYARD_CREDENTIAL_SYNC_SOURCED:-}" ] && return 0
SUBYARD_CREDENTIAL_SYNC_SOURCED=1

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
