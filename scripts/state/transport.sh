#!/usr/bin/env bash
# transport.sh — remote owner control plane and direct yard data-plane probes.
# shellcheck disable=SC2034 # REMOTE_SSH_ERROR is an intentional diagnostic out-parameter.

[ -n "${SUBYARD_STATE_TRANSPORT_SOURCED:-}" ] && return 0
SUBYARD_STATE_TRANSPORT_SOURCED=1

# --- remote data plane -------------------------------------------------------
# A remote context (YARD_TYPE=remote) has NO local incus: the data-plane scripts reach the yard
# only through its ProxyJump ssh alias ($SSH_HOST = yard-<name>). These helpers replace the incus
# RUNNING probe with an ssh reachability probe and centralise the "start it on the owner host" hint.

# yard_is_remote — true when the loaded context is a remote yard.
yard_is_remote() { [ "${YARD_TYPE:-local}" = remote ]; }

# remote_start_hint — a command in the ACTIVE remote context. The dispatcher forwards `start`
# to the owner host, so the operator does not need to reconstruct the owner-host ssh command.
remote_start_hint() {
  if [ -n "${YARD_NAME:-}" ] && yard_valid_name "$YARD_NAME"; then
    printf 'run: %s -Y %s start' "${PROG:-yard}" "$YARD_NAME"
  else
    printf 'start it on the owner host: ssh %s -- yard%s start' \
      "${REMOTE_DEST:-<dest>}" "${REMOTE_YARD:+ -Y $REMOTE_YARD}"
  fi
}

# remote_owner_yard_cmd — run one non-interactive yard command in the remote yard's owner-host
# context. Arguments are quoted token-by-token across ssh + the remote login shell. This is the
# control-plane companion to the direct yard data plane and carries no project source path.
remote_owner_yard_cmd() {
  local dest="${REMOTE_DEST:-}" ryard="${REMOTE_YARD:-}" rc='yard' a
  [ -n "$dest" ] || return 1
  [ -n "$ryard" ] && rc="$rc -Y $(printf '%q' "$ryard")"
  for a in "$@"; do rc="$rc $(printf '%q' "$a")"; done
  ssh -o BatchMode=yes -o ConnectTimeout="${SUBYARD_REMOTE_TIMEOUT:-10}" \
      -o StrictHostKeyChecking=accept-new "$dest" -- bash -lc "$(printf '%q' "$rc")"
}

# remote_alias_configured — distinguish a missing/legacy snippet from a network failure. `ssh -G`
# resolves Includes without opening a connection; the managed alias must expose this context's
# stable HostKeyAlias. A legacy snippet therefore gets the useful "re-run remote add" diagnosis.
remote_alias_configured() {
  local expected cfg got
  expected="$(remote_hostkey_alias "${YARD_NAME:-}" 2>/dev/null)" || return 1
  cfg="$(ssh -G "${SSH_HOST:-yard}" 2>/dev/null)" || return 1
  got="$(awk '$1=="hostkeyalias" { print $2; exit }' <<<"$cfg")"
  [ "$got" = "$expected" ]
}

# yard_reachable — probe the yard over its ssh alias (BatchMode + short timeout so a down yard
# fails fast). Preserve stderr in-memory for classification, but never echo the raw diagnostic:
# ssh/config errors may contain private host aliases or local paths.
REMOTE_SSH_ERROR=''
yard_reachable() {
  if REMOTE_SSH_ERROR="$(ssh -o BatchMode=yes -o ConnectTimeout=5 \
      "${SSH_HOST:-yard}" true 2>&1 >/dev/null)"; then
    REMOTE_SSH_ERROR=''
    return 0
  fi
  return 1
}

# remote_owner_info — control-plane probe used only after the data plane failed. Its success
# separates an unreachable owner host from a stopped yard or a broken loopback proxy/sshd.
remote_owner_info() {
  local dest="${REMOTE_DEST:-}" ryard="${REMOTE_YARD:-}" rc='yard _info'
  [ -n "$dest" ] || return 1
  [ -n "$ryard" ] && rc="yard -Y $(printf '%q' "$ryard") _info"
  ssh -o BatchMode=yes -o ConnectTimeout="${SUBYARD_REMOTE_TIMEOUT:-5}" \
      -o StrictHostKeyChecking=accept-new "$dest" -- bash -lc "$(printf '%q' "$rc")" 2>/dev/null
}

# require_remote_reachable — classify the failure instead of turning every ssh error into a
# false "start it" hint. Callers use it in place of the local incus preflight.
require_remote_reachable() {
  remote_alias_configured \
    || die "ssh alias '${SSH_HOST:-yard}' is missing or legacy — re-run '$(remote_add_hint "${YARD_NAME:-<name>}" "${REMOTE_DEST:-<dest>}" "${REMOTE_YARD:-}")' to regenerate it"
  yard_reachable && return 0

  local json='' state=''
  json="$(remote_owner_info)" \
    || die "the owner host for remote yard '${YARD_NAME:-?}' is unreachable — check its ssh access, host key and network"
  case "$json" in '{'*'}') ;; *) die "the owner host answered, but 'yard _info' did not — check its Subyard installation" ;; esac

  # The owner probe succeeded, so these diagnostics belong to the in-yard ssh hop rather than
  # the ProxyJump host itself.
  case "$REMOTE_SSH_ERROR" in
    *'REMOTE HOST IDENTIFICATION HAS CHANGED'* | *'Host key verification failed'* | *'Offending '*key*)
      die "ssh host key changed for '$(remote_hostkey_alias "$YARD_NAME")' — access is blocked; verify it on the owner host, then run '${PROG:-yard} remote repair-key $YARD_NAME'" ;;
  esac

  state="$(json_str "$json" state)"
  case "$state" in
    RUNNING) ;;
    STOPPED | FROZEN) die "remote yard state is $state — $(remote_start_hint)" ;;
    '' | UNKNOWN) die "the owner host is reachable, but its Incus state is unknown — check Incus on the owner host" ;;
    *) die "remote yard state is $state — $(remote_start_hint)" ;;
  esac

  case "$REMOTE_SSH_ERROR" in
    *'Permission denied'* | *'no mutual signature algorithm'* | *'Too many authentication failures'*)
      die "the remote yard rejected this controller's ssh key — re-run '$(remote_add_hint "$YARD_NAME" "${REMOTE_DEST:-<dest>}" "${REMOTE_YARD:-}")' to authorize it and verify the data plane" ;;
  esac

  case "$REMOTE_SSH_ERROR" in
    *'Could not resolve hostname'* | *'Bad configuration option'* | *'no argument after keyword'* | *'percent_expand'*)
      die "ssh alias '${SSH_HOST:-yard}' is invalid — re-run '$(remote_add_hint "$YARD_NAME" "${REMOTE_DEST:-<dest>}" "${REMOTE_YARD:-}")' to regenerate it" ;;
    *'Connection refused'* | *'Connection timed out'* | *'Operation timed out'* | \
    *'kex_exchange_identification'* | *'stdio forwarding failed'* | *'administratively prohibited'* | \
    *'Connection closed'*)
      die "the owner host and remote instance are reachable, but the yard loopback proxy or sshd is not — run '${PROG:-yard} -Y $YARD_NAME status' and check sshd on the owner host" ;;
    *)
      die "the remote yard data plane failed through ssh alias '${SSH_HOST:-yard}' — run 'ssh ${SSH_HOST:-yard} true' to inspect the SSH diagnostic" ;;
  esac
}
