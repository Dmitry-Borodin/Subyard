#!/usr/bin/env bash
# peers.sh — peer enrollment, trust and assignment policy orchestration.

[ -n "${SUBYARD_CREDENTIAL_PEERS_SOURCED:-}" ] && return 0
SUBYARD_CREDENTIAL_PEERS_SOURCED=1

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
