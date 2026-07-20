#!/usr/bin/env bash
# transport.sh — local/owner-host SSH peer command transport.

[ -n "${SUBYARD_CREDENTIAL_TRANSPORT_SOURCED:-}" ] && return 0
SUBYARD_CREDENTIAL_TRANSPORT_SOURCED=1

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
