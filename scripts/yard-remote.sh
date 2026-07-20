#!/usr/bin/env bash
# yard-remote.sh — manage REMOTE yards: an external host running Subyard, driven as if local.
#   remote add <name> <user@host|ssh-alias> [--yard <remote-yard-name>]
#       Probe the host's `yard _info` over ssh, register a machine-local context
#       (~/.config/subyard/yards/<name>.env, YARD_TYPE=remote), generate the ProxyJump ssh
#       alias 'yard-<name>' (data plane: code/ssh/sync), and authorize this controller's
#       public key in the remote yard. Lifecycle commands then FORWARD to the owner host
#       (`yard -Y <name> status|start|…`), data-plane commands go straight into the yard.
#   remote repair-key <name> verify and rotate one remote context's pinned in-yard host key.
#   remote remove <name>    drop the context + ssh alias + its in-yard trust pin.
#   remote list             one row per remote yard: name, dest, remote yard, port, last seen.
# Trust: an account on the remote host = full trust of it. Registration copies no credentials;
# only a later `yard keys trust` permits encrypted credential exchange between owner hosts.
# Host materialization remains on the owner host. Agent-forwarding is OFF by default.
# Config: config/host.env (SUBYARD_HOME/SUBYARD_CONFIG_HOME) + scripts/lib/registry.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

PROG="${PROG:-yard}"                             # the dispatcher does not export it; user-facing name
REG_DIR="${SUBYARD_CONFIG_HOME:-$SUBYARD_OPERATOR_HOME/.config/subyard}/yards"
SSH_DIR="$HOME/.ssh"
CM_DIR="$SUBYARD_HOME/ssh"                       # ControlPath sockets + known_hosts live here
CONNECT_TIMEOUT="${SUBYARD_REMOTE_TIMEOUT:-10}"  # add-time probe budget (yards/status use 2s)

# JSON scrapers (json_str/json_num), the env-file reader (yard_env_val) and age_human live in
# source-only control-plane modules — used below unqualified.

# ssh options shared by every control-plane call. accept-new records an unknown host key on
# first contact (and refuses a CHANGED one) without an interactive prompt.
ssh_ctl() {
  ssh -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT" \
      -o StrictHostKeyChecking=accept-new "$@"
}

# Run `yard [-Y <ryard>] <args…>` on the owner host, quoting twice: once so the remote bash
# gets each token intact, once more so ssh's space-join + the remote login shell deliver the
# whole line as a single argument to `bash -lc`.
remote_yard_cmd() {   # <dest> <ryard> <args…>
  local dest="$1" ryard="$2"; shift 2
  local rc='yard' a
  [ -n "$ryard" ] && rc="$rc -Y $(printf '%q' "$ryard")"
  for a in "$@"; do rc="$rc $(printf '%q' "$a")"; done
  ssh_ctl "$dest" -- bash -lc "$(printf '%q' "$rc")"
}

# A remote destination is written into a sourced env file and an OpenSSH ProxyJump directive.
# Accept the normal user@host / ssh-alias / bracketed-IPv6 shapes, but no shell or config syntax.
valid_remote_dest() {
  case "${1:-}" in
    '' | -* | *[!a-zA-Z0-9_.@:\[\]+-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Best-effort owner-host fingerprint for the operator to eyeball on first contact. Resolves the
# dest (which may be an ssh-alias) to hostname/port via `ssh -G`, then reads the recorded key.
show_owner_fingerprint() {   # <dest>
  local dest="$1" hn port target fp
  hn="$(ssh -G "$dest" 2>/dev/null | awk '$1=="hostname"{print $2; exit}')" || hn=''
  port="$(ssh -G "$dest" 2>/dev/null | awk '$1=="port"{print $2; exit}')" || port='22'
  [ -n "$hn" ] || { info "owner-host key recorded (accept-new)"; return 0; }
  target="$hn"; [ "${port:-22}" != 22 ] && target="[$hn]:$port"
  fp="$(ssh-keygen -F "$target" -l 2>/dev/null | grep -v '^#' | head -n1)" || fp=''
  if [ -n "$fp" ]; then info "owner-host key ($hn): $fp"; else info "owner-host key for $hn recorded (accept-new)"; fi
}

hostkey_alias_for() {   # <validated-context-name>
  remote_hostkey_alias "$1" || die "invalid remote context name '$1'"
}

known_entry_keys() {   # <HostKeyAlias>; known_hosts-formatted lines, without comments
  local alias="$1" known="$CM_DIR/known_hosts"
  [ -f "$known" ] || return 0
  ssh-keygen -F "$alias" -f "$known" 2>/dev/null | grep -v '^#' || true
}

print_key_fingerprints() {   # <label> <known_hosts-formatted-keys>
  local label="$1" keys="$2" fp any=0
  [ -n "$keys" ] || { info "$label: unavailable"; return 0; }
  while IFS= read -r fp; do
    [ -n "$fp" ] || continue
    any=1; info "$label: $fp"
  done < <(printf '%s\n' "$keys" | ssh-keygen -lf - 2>/dev/null || true)
  [ "$any" = 1 ] || info "$label: unavailable"
}

# Ask the already-pinned owner host to scan the yard's loopback sshd. The result is only used for
# operator-visible fingerprints and repair verification; it never bypasses the final SSH check.
scan_yard_host_keys() {   # <dest> <port>
  local dest="$1" port="$2" rc
  rc="ssh-keyscan -T $CONNECT_TIMEOUT -p $port 127.0.0.1 2>/dev/null"
  ssh_ctl "$dest" -- bash -lc "$(printf '%q' "$rc")"
}

show_yard_fingerprint() {   # <context-name>
  local alias keys
  alias="$(hostkey_alias_for "$1")"
  keys="$(known_entry_keys "$alias")"
  print_key_fingerprints "yard ssh key ($alias)" "$keys"
}

# Resolve THIS controller's public key + matching identity, same order as 07-ssh-access.sh:
# $SUBYARD_SSH_PUBKEY, then ~/.ssh/id_*.pub, else a dedicated key under $SUBYARD_HOME/ssh.
# Sets PUBKEY / PUBKEY_FILE / IDENTITY. (Generating a key is a mutation — call after proceed.)
resolve_pubkey() {
  PUBKEY_FILE=''
  if [ -n "${SUBYARD_SSH_PUBKEY:-}" ]; then
    PUBKEY_FILE="$SUBYARD_SSH_PUBKEY"
  else
    local k
    for k in id_ed25519 id_ecdsa id_rsa; do
      [ -f "$SSH_DIR/$k.pub" ] && { PUBKEY_FILE="$SSH_DIR/$k.pub"; break; }
    done
  fi
  if [ -z "$PUBKEY_FILE" ]; then
    install -d -m 700 "$CM_DIR"
    [ -f "$CM_DIR/id_ed25519" ] || {
      ssh-keygen -t ed25519 -N "" -C "subyard-remote" -f "$CM_DIR/id_ed25519" >/dev/null
      info "no ssh key found — generated a dedicated one: $CM_DIR/id_ed25519"
    }
    PUBKEY_FILE="$CM_DIR/id_ed25519.pub"
  fi
  [ -r "$PUBKEY_FILE" ] || die "cannot read public key: $PUBKEY_FILE"
  PUBKEY="$(cat "$PUBKEY_FILE")"
  IDENTITY="${PUBKEY_FILE%.pub}"
}

snip_path()  { printf '%s/subyard-%s.config' "$SSH_DIR" "$1"; }   # per-yard ssh alias snippet
# last-good _info JSON + epoch cache lives at remote_cache_path (lib/cache.sh)

# Render the per-remote-yard ssh alias to a caller-provided SAME-DIRECTORY temporary file. The
# transaction below atomically renames it into place only after all rendering succeeds.
write_alias_file() {   # <path> <name> <dest> <port> <devuser> <identity>
  local path="$1" name="$2" dest="$3" port="$4" devuser="$5" identity="$6" hostkey_alias
  hostkey_alias="$(hostkey_alias_for "$name")"
  local known="$CM_DIR/known_hosts"
  cat > "$path" <<EOF
# Managed by Subyard (scripts/yard-remote.sh) — regenerated on 'yard remote add'; do not edit.
Host yard-$name
    HostName 127.0.0.1
    Port $port
    User $devuser
    ProxyJump $dest
    HostKeyAlias $hostkey_alias
    IdentityFile $identity
    IdentitiesOnly yes
    ForwardAgent no
    ControlMaster auto
    ControlPath $CM_DIR/cm-remote-$name-%r@%h:%p
    ControlPersist 60s
    StrictHostKeyChecking accept-new
    UserKnownHostsFile $known
EOF
  chmod 600 "$path"
}

write_context_file() {   # <path> <existing-file-or-empty> <name> <dest> <ryard> <port> <devuser>
  local path="$1" existing="$2" name="$3" dest="$4" ryard="$5" port="$6" devuser="$7" overrides=''
  if [ -f "$existing" ]; then
    if grep -qxF '# --- Subyard user overrides (preserved by remote add) ---' "$existing"; then
      overrides="$(sed '1,/^# --- Subyard user overrides (preserved by remote add) ---$/d' "$existing")"
    else
      # Legacy generated contexts had no marker. Preserve assignment-only custom settings, plus
      # an explicit agent-forwarding opt-in, while regenerating every managed mapping field.
      overrides="$(awk -F= '
        /^[A-Za-z_][A-Za-z0-9_]*=/ {
          key=$1
          if (key=="YARD_TYPE" || key=="REMOTE_DEST" || key=="REMOTE_YARD" ||
              key=="REMOTE_SSH_PORT" || key=="REMOTE_DEV_USER" || key=="SSH_PORT") next
          if (key=="FORWARD_SSH_AGENT" && $0=="FORWARD_SSH_AGENT=0") next
          print
        }
      ' "$existing")"
    fi
  fi
  cat > "$path" <<EOF
# Subyard remote yard '$name' — generated by 'yard remote add' on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Machine-local (do NOT commit). Reached over SSH: lifecycle commands forward to the owner host,
# data-plane (code/ssh/sync) goes straight into the yard via the 'yard-$name' ProxyJump alias.
YARD_TYPE=remote
REMOTE_DEST=$dest
REMOTE_YARD=$ryard
REMOTE_SSH_PORT=$port
REMOTE_DEV_USER=$devuser
# Mirror the port for the local context view; agent-forwarding is off unless explicitly
# overridden in the preserved user section below.
SSH_PORT=$port
FORWARD_SSH_AGENT=0
# --- Subyard user overrides (preserved by remote add) ---
EOF
  [ -z "$overrides" ] || printf '%s\n' "$overrides" >> "$path"
  chmod 600 "$path"
}

write_config_file() {   # <path> <current-config> <snippet-basename>
  local path="$1" cfg="$2" snip_name="$3"
  if [ -f "$cfg" ]; then cp -p "$cfg" "$path"; else : > "$path"; fi
  # OpenSSH uses the first obtained value for most keywords. Keep the managed Include at the
  # front even if a user moved it below Host/Match blocks; remove duplicates while doing so.
  local prepended="$path.prepend"
  {
    printf 'Include %s\n' "$snip_name"
    grep -vxF "Include $snip_name" "$path" || true
  } > "$prepended" && mv -f "$prepended" "$path"
  chmod 600 "$path"
}

# Drop this remote yard's ssh alias + its Include line (idempotent).
remove_alias() {   # <name>
  local name="$1" snip; snip="$(snip_path "$name")"; local snip_name; snip_name="$(basename "$snip")"
  local cfg="$SSH_DIR/config"
  [ -f "$snip" ] && { rm -f "$snip"; ok "removed ssh alias file ~/.ssh/$snip_name"; }
  if [ -f "$cfg" ] && grep -qxF "Include $snip_name" "$cfg"; then
    { grep -vxF "Include $snip_name" "$cfg" || true; } > "$cfg.tmp" && mv -f "$cfg.tmp" "$cfg"
    ok "removed the Include line from ~/.ssh/config"
  fi
}

remove_hostkey_pin() {   # <name>; exact HostKeyAlias only, never endpoint/port based
  local name="$1" alias known="$CM_DIR/known_hosts" staged
  alias="$(hostkey_alias_for "$name")"
  [ -f "$known" ] || return 0
  if [ -n "$(known_entry_keys "$alias")" ]; then
    staged="$(mktemp "$CM_DIR/.known_hosts.remove.XXXXXX")" \
      || die "could not stage removal of ssh host-key pin '$alias'"
    cp -p "$known" "$staged" \
      && ssh-keygen -R "$alias" -f "$staged" >/dev/null 2>&1 \
      && rm -f "$staged.old" \
      && mv -f "$staged" "$known" \
      || { rm -f "$staged" "$staged.old"; die "could not remove ssh host-key pin '$alias' from $known"; }
    ok "removed yard ssh trust pin '$alias'"
  fi
}

# Persist the last good probe so `yard yards`/`status --all` show a last-seen state when the
# host is briefly unreachable. Format: line 1 = epoch seconds, line 2 = the _info JSON.
write_cache() {   # <name> <json>
  local name="$1" json="$2" c; c="$(remote_cache_path "$name")"
  install -d -m 700 "$SUBYARD_HOME" 2>/dev/null || return 0
  json="$(remote_info_keep_cached_projects "$json" "$c")"
  { printf '%s\n' "$(date +%s)"; printf '%s\n' "$json"; } > "$c.tmp" && mv -f "$c.tmp" "$c"
}

DATA_PROBE_ERROR=''
probe_data_plane() {   # <name>
  # Never reuse an existing master here: add/repair must perform a fresh host-key handshake.
  if DATA_PROBE_ERROR="$(ssh -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT" \
      -o ControlMaster=no -o ControlPath=none \
      "yard-$1" true 2>&1 >/dev/null)"; then
    DATA_PROBE_ERROR=''
    return 0
  fi
  return 1
}

restore_tx_file() {   # <target> <backup> <existed:0|1>
  local target="$1" backup="$2" existed="$3"
  if [ "$existed" = 1 ]; then mv -f "$backup" "$target"; else rm -f "$target" "$backup"; fi
}

cleanup_tx_files() {
  local path
  for path in "$@"; do [ -n "$path" ] && rm -f "$path" "$path.prepend"; done
}

# Stage context/snippet/config beside their destinations, atomically install them, then require
# the real data plane to work. Any failure restores all prior local files AND known_hosts, so a
# retry never sees a half-registered context or a trust pin learned by an unsuccessful probe.
REGISTER_TX_ERROR=''
register_transaction() {   # <env-file> <name> <dest> <ryard> <port> <devuser> <identity>
  local env_file="$1" name="$2" dest="$3" ryard="$4" port="$5" devuser="$6" identity="$7"
  local snip cfg="$SSH_DIR/config" known="$CM_DIR/known_hosts" snip_name
  snip="$(snip_path "$name")"; snip_name="$(basename "$snip")"
  local env_stage='' snip_stage='' cfg_stage='' env_backup='' snip_backup='' cfg_backup='' known_backup=''
  local env_had=0 snip_had=0 cfg_had=0 known_had=0

  REGISTER_TX_ERROR=''
  install -d -m 700 "$(dirname "$env_file")" "$SSH_DIR" "$CM_DIR" \
    || { REGISTER_TX_ERROR='could not create local registry/ssh directories'; return 1; }
  env_stage="$(mktemp "$(dirname "$env_file")/.${name}.env.stage.XXXXXX")" \
    || { REGISTER_TX_ERROR='could not stage the remote context'; return 1; }
  snip_stage="$(mktemp "$SSH_DIR/.subyard-${name}.config.stage.XXXXXX")" \
    || { rm -f "$env_stage"; REGISTER_TX_ERROR='could not stage the ssh alias'; return 1; }
  cfg_stage="$(mktemp "$SSH_DIR/.config.stage.XXXXXX")" \
    || { rm -f "$env_stage" "$snip_stage"; REGISTER_TX_ERROR='could not stage ~/.ssh/config'; return 1; }
  env_backup="$(mktemp "$(dirname "$env_file")/.${name}.env.rollback.XXXXXX")" \
    || { rm -f "$env_stage" "$snip_stage" "$cfg_stage"; REGISTER_TX_ERROR='could not prepare context rollback'; return 1; }
  snip_backup="$(mktemp "$SSH_DIR/.subyard-${name}.config.rollback.XXXXXX")" \
    || { rm -f "$env_stage" "$snip_stage" "$cfg_stage" "$env_backup"; REGISTER_TX_ERROR='could not prepare alias rollback'; return 1; }
  cfg_backup="$(mktemp "$SSH_DIR/.config.rollback.XXXXXX")" \
    || { rm -f "$env_stage" "$snip_stage" "$cfg_stage" "$env_backup" "$snip_backup"; REGISTER_TX_ERROR='could not prepare ssh config rollback'; return 1; }
  known_backup="$(mktemp "$CM_DIR/.known_hosts.rollback.XXXXXX")" \
    || { rm -f "$env_stage" "$snip_stage" "$cfg_stage" "$env_backup" "$snip_backup" "$cfg_backup"; REGISTER_TX_ERROR='could not prepare host-key rollback'; return 1; }

  write_context_file "$env_stage" "$env_file" "$name" "$dest" "$ryard" "$port" "$devuser" \
    || { REGISTER_TX_ERROR='could not render the remote context'; cleanup_tx_files "$env_stage" "$snip_stage" "$cfg_stage" "$env_backup" "$snip_backup" "$cfg_backup" "$known_backup"; return 1; }
  write_alias_file "$snip_stage" "$name" "$dest" "$port" "$devuser" "$identity" \
    || { REGISTER_TX_ERROR='could not render the ssh alias'; cleanup_tx_files "$env_stage" "$snip_stage" "$cfg_stage" "$env_backup" "$snip_backup" "$cfg_backup" "$known_backup"; return 1; }
  write_config_file "$cfg_stage" "$cfg" "$snip_name" \
    || { REGISTER_TX_ERROR='could not render ~/.ssh/config'; cleanup_tx_files "$env_stage" "$snip_stage" "$cfg_stage" "$env_backup" "$snip_backup" "$cfg_backup" "$known_backup"; return 1; }

  if [ -f "$env_file" ]; then
    cp -p "$env_file" "$env_backup" \
      || { REGISTER_TX_ERROR='could not back up the existing context'; cleanup_tx_files "$env_stage" "$snip_stage" "$cfg_stage" "$env_backup" "$snip_backup" "$cfg_backup" "$known_backup"; return 1; }
    env_had=1
  fi
  if [ -f "$snip" ]; then
    cp -p "$snip" "$snip_backup" \
      || { REGISTER_TX_ERROR='could not back up the existing ssh alias'; cleanup_tx_files "$env_stage" "$snip_stage" "$cfg_stage" "$env_backup" "$snip_backup" "$cfg_backup" "$known_backup"; return 1; }
    snip_had=1
  fi
  if [ -f "$cfg" ]; then
    cp -p "$cfg" "$cfg_backup" \
      || { REGISTER_TX_ERROR='could not back up ~/.ssh/config'; cleanup_tx_files "$env_stage" "$snip_stage" "$cfg_stage" "$env_backup" "$snip_backup" "$cfg_backup" "$known_backup"; return 1; }
    cfg_had=1
  fi
  if [ -f "$known" ]; then
    cp -p "$known" "$known_backup" \
      || { REGISTER_TX_ERROR='could not back up known_hosts'; cleanup_tx_files "$env_stage" "$snip_stage" "$cfg_stage" "$env_backup" "$snip_backup" "$cfg_backup" "$known_backup"; return 1; }
    known_had=1
  fi

  if ! mv -f "$env_stage" "$env_file"; then REGISTER_TX_ERROR='could not install the remote context'
  elif ! mv -f "$snip_stage" "$snip"; then REGISTER_TX_ERROR='could not install the ssh alias'
  elif ! mv -f "$cfg_stage" "$cfg"; then REGISTER_TX_ERROR='could not install ~/.ssh/config'
  elif probe_data_plane "$name"; then
    rm -f "$env_backup" "$snip_backup" "$cfg_backup" "$known_backup"
    return 0
  else
    REGISTER_TX_ERROR='data-plane probe failed'
  fi

  local rollback_failed=0
  restore_tx_file "$known" "$known_backup" "$known_had" || rollback_failed=1
  restore_tx_file "$cfg" "$cfg_backup" "$cfg_had" || rollback_failed=1
  restore_tx_file "$snip" "$snip_backup" "$snip_had" || rollback_failed=1
  restore_tx_file "$env_file" "$env_backup" "$env_had" || rollback_failed=1
  cleanup_tx_files "$env_stage" "$snip_stage" "$cfg_stage"
  if [ "$rollback_failed" = 1 ]; then
    REGISTER_TX_ERROR="$REGISTER_TX_ERROR; local rollback was incomplete — inspect $env_file, $snip, $cfg and $known"
    return 3
  fi
  return 2
}

report_hostkey_mismatch() {   # <name> <dest> <ryard> <port>
  local name="$1" dest="$2" ryard="$3" port="$4" alias old_keys new_keys verify
  alias="$(hostkey_alias_for "$name")"
  old_keys="$(known_entry_keys "$alias")"
  new_keys="$(scan_yard_host_keys "$dest" "$port" 2>/dev/null || true)"
  printf '  %s[fail]%s yard ssh host key changed for %s; refusing automatic replacement\n' "$C_BAD" "$C_OFF" "$alias" >&2
  print_key_fingerprints "recorded yard ssh key" "$old_keys" >&2
  print_key_fingerprints "owner-host scan of the current yard key" "$new_keys" >&2
  verify="ssh $dest -- yard${ryard:+ -Y $ryard} shell --root -- ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
  info "verify from the trusted owner host: $verify" >&2
  die "only after the fingerprints match, run: $PROG remote repair-key $name"
}

diagnose_add_probe_failure() {   # <name> <dest> <ryard> <port> <info-json>
  local name="$1" dest="$2" ryard="$3" port="$4" json="$5" state
  case "$DATA_PROBE_ERROR" in
    *'REMOTE HOST IDENTIFICATION HAS CHANGED'* | *'Host key verification failed'* | *'Offending '*key*)
      report_hostkey_mismatch "$name" "$dest" "$ryard" "$port" ;;
    *'Permission denied'* | *'no mutual signature algorithm'* | *'Too many authentication failures'*)
      die "the yard sshd rejected the controller key after authorization — check 'yard _authorize' and sshd, then re-run '$(remote_add_hint "$name" "$dest" "$ryard")'" ;;
  esac
  state="$(json_str "$json" state)"
  case "$state" in
    RUNNING) ;;
    STOPPED | FROZEN) die "remote yard state is $state — start it on the owner host, then re-run '$(remote_add_hint "$name" "$dest" "$ryard")'" ;;
    '' | UNKNOWN) die "the owner host is reachable, but its Incus state is unknown — check Incus there before retrying remote add" ;;
    *) die "remote yard state is $state — start or repair it on the owner host before retrying remote add" ;;
  esac
  die "the owner host and instance are reachable, but the yard loopback proxy or sshd failed the final probe; run 'ssh yard-$name true' after checking the owner host"
}

key_material() {   # known_hosts lines -> "algorithm base64" records
  awk '{ for (i=1; i<NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) { print $i " " $(i+1); break } }'
}

# --- remote repair-key ------------------------------------------------------
# Explicit, confirmed rotation only. The new key is scanned through the already-trusted owner
# host, shown to the operator, then accepted by the normal ProxyJump connection. The recorded key
# must match that scan; otherwise the original known_hosts is restored.
cmd_repair_key() {
  local name=''
  while [ $# -gt 0 ]; do
    case "$1" in
      -y | --yes) shift ;;
      -*) die "remote repair-key: unknown option '$1'" ;;
      *) [ -z "$name" ] && { name="$1"; shift; } || die "remote repair-key: unexpected argument '$1'" ;;
    esac
  done
  [ -n "$name" ] || die "usage: $PROG remote repair-key <name>"
  yard_valid_name "$name" || die "invalid remote context name '$name'"

  local env_file dest ryard port json current_port state alias known old_keys new_keys old_material new_material
  env_file="$(yard_env_file "$name" 2>/dev/null)" || die "no such yard '$name' — see '$PROG yards'"
  [ "$(yard_env_val "$env_file" YARD_TYPE)" = remote ] \
    || die "'$name' is a LOCAL yard, not a remote one"
  dest="$(yard_env_val "$env_file" REMOTE_DEST)"; ryard="$(yard_env_val "$env_file" REMOTE_YARD)"
  port="$(yard_env_val "$env_file" REMOTE_SSH_PORT)"; alias="$(hostkey_alias_for "$name")"
  known="$CM_DIR/known_hosts"

  info "probing the trusted owner host before rotating '$alias'…"
  json="$(remote_yard_cmd "$dest" "$ryard" _info 2>/dev/null)" \
    || die "the owner host is unreachable — no host-key state was changed"
  case "$json" in '{'*'}') ;; *) die "the owner host did not return yard _info JSON — no host-key state was changed" ;; esac
  current_port="$(json_num "$json" sshPort)"; state="$(json_str "$json" state)"
  [ "$current_port" = "$port" ] \
    || die "the remote ssh port changed from ${port:-?} to ${current_port:-?}; verify the rebuild, then remove and re-add the context explicitly"
  [ "$state" = RUNNING ] \
    || die "remote yard state is ${state:-UNKNOWN} — start it before repairing its ssh host key"
  show_owner_fingerprint "$dest"

  old_keys="$(known_entry_keys "$alias")"
  [ -n "$old_keys" ] \
    || die "there is no recorded key for '$alias' — re-run '$(remote_add_hint "$name" "$dest" "$ryard")' instead"
  new_keys="$(scan_yard_host_keys "$dest" "$port" 2>/dev/null || true)"
  [ -n "$new_keys" ] \
    || die "the owner host could not scan the yard sshd on 127.0.0.1:$port — check the loopback proxy and sshd"
  old_material="$(printf '%s\n' "$old_keys" | key_material | sort -u)"
  new_material="$(printf '%s\n' "$new_keys" | key_material | sort -u)"
  if [ -n "$old_material" ] && grep -qxF -f <(printf '%s\n' "$old_material") <<<"$new_material"; then
    die "the recorded key for '$alias' already matches the owner-host scan — no rotation is needed; re-run remote add to check the full data plane"
  fi

  print_key_fingerprints "recorded yard ssh key" "$old_keys"
  print_key_fingerprints "owner-host scan of the new yard ssh key" "$new_keys"
  info "verify independently: ssh $dest -- yard${ryard:+ -Y $ryard} shell --root -- ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
  announce "Rotate remote yard ssh key '$alias'" \
    "Delete only the '$alias' entry from $known (other contexts and endpoint keys stay untouched)." \
    "Reconnect through 'yard-$name' with strict accept-new checking." \
    "Require the accepted key to match the owner-host scan; restore the old trust file on failure."
  proceed_or_die

  local staged backup recorded_material matched=0 line
  staged="$(mktemp "$CM_DIR/.known_hosts.repair.XXXXXX")" \
    || die "could not stage known_hosts repair"
  backup="$(mktemp "$CM_DIR/.known_hosts.rollback.XXXXXX")" \
    || { rm -f "$staged"; die "could not stage known_hosts rollback"; }
  cp -p "$known" "$staged" && cp -p "$known" "$backup" \
    || { rm -f "$staged" "$backup"; die "could not back up known_hosts"; }
  if ! ssh-keygen -R "$alias" -f "$staged" >/dev/null 2>&1; then
    rm -f "$staged" "$staged.old" "$backup"
    die "could not remove only '$alias' from the staged known_hosts"
  fi
  rm -f "$staged.old"
  mv -f "$staged" "$known"

  if ! probe_data_plane "$name"; then
    mv -f "$backup" "$known"
    case "$DATA_PROBE_ERROR" in
      *'Permission denied'*) die "the new host key was not kept because the controller key was rejected — re-run remote add" ;;
      *'REMOTE HOST IDENTIFICATION HAS CHANGED'* | *'Host key verification failed'*)
        die "the key seen through ProxyJump did not match the repaired trust state; the old key was restored" ;;
      *) die "the repaired data-plane probe failed; the old key was restored (check the loopback proxy/sshd)" ;;
    esac
  fi

  recorded_material="$(known_entry_keys "$alias" | key_material | sort -u)"
  while IFS= read -r line; do
    [ -n "$line" ] && grep -qxF "$line" <<<"$new_material" && { matched=1; break; }
  done <<<"$recorded_material"
  if [ "$matched" != 1 ]; then
    mv -f "$backup" "$known"
    die "the key accepted through ProxyJump does not match the owner-host scan; the old key was restored"
  fi
  rm -f "$backup"
  show_yard_fingerprint "$name"
  ok "remote yard ssh key '$alias' rotated and the data plane verified."
}

# --- remote add --------------------------------------------------------------
cmd_add() {
  local name='' dest='' ryard=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --yard) [ $# -ge 2 ] || die "remote add: --yard needs a name"; ryard="$2"; shift 2 ;;
      --yard=*) ryard="${1#--yard=}"; shift ;;
      -y|--yes) shift ;;                       # consumed by ui.sh; ignore positionally
      -*) die "remote add: unknown option '$1'" ;;
      *) if [ -z "$name" ]; then name="$1"; elif [ -z "$dest" ]; then dest="$1";
         else die "remote add: unexpected argument '$1'"; fi; shift ;;
    esac
  done
  [ -n "$name" ] && [ -n "$dest" ] || die "usage: $PROG remote add <name> <user@host|ssh-alias> [--yard <remote-yard>]"
  yard_valid_name "$name" \
    || die "invalid yard name '$name' (allowed: lowercase letters, digits, '-', '_'; must start with a letter or digit)"
  [ -n "$ryard" ] && { yard_valid_name "$ryard" || die "invalid --yard name '$ryard'"; }
  valid_remote_dest "$dest" \
    || die "invalid ssh destination '$dest' (use a single user@host or ssh alias, without whitespace or shell/config syntax)"

  # An identical remote mapping is an idempotent refresh/migration. Local contexts and rebinding
  # an existing name to a different owner/yard remain fail-closed and require explicit removal.
  local existing='' existing_file='' env_file="$REG_DIR/$name.env" refresh=0 old_dest old_ryard
  while IFS= read -r existing; do
    [ "$existing" = "$name" ] || continue
    existing_file="$(yard_env_file "$name" 2>/dev/null || true)"
    [ -n "$existing_file" ] \
      || die "a LOCAL yard named '$name' already exists — pick another name"
    [ "$(yard_env_val "$existing_file" YARD_TYPE)" = remote ] \
      || die "'$name' is a LOCAL yard — remote add cannot replace it"
    old_dest="$(yard_env_val "$existing_file" REMOTE_DEST)"
    old_ryard="$(yard_env_val "$existing_file" REMOTE_YARD)"
    if [ "$old_dest" != "$dest" ] || [ "$old_ryard" != "$ryard" ]; then
      die "remote yard '$name' is already mapped to $old_dest (yard ${old_ryard:-<default>}) — run '$PROG remote remove $name' before rebinding it"
    fi
    env_file="$existing_file"; refresh=1
    break
  done < <(yard_registry_names)

  info "probing $dest (yard ${ryard:-<default>} _info)…"
  local json
  json="$(remote_yard_cmd "$dest" "$ryard" _info 2>/dev/null)" \
    || die "cannot reach '$dest' or run 'yard _info' there — is Subyard installed and is your ssh access working? (try: ssh $dest -- yard _info)"
  case "$json" in
    '{'*'}') ;;   # a flat JSON object as _info emits
    *) die "'$dest' answered but not with yard _info JSON — check the remote yard's version (got: ${json:0:60})" ;;
  esac
  show_owner_fingerprint "$dest"

  local rport rdev rver rstate
  rport="$(json_num "$json" sshPort)"; rdev="$(json_str "$json" devUser)"
  rver="$(json_str "$json" version)"; rstate="$(json_str "$json" state)"
  [ -n "$rport" ] && [ "$rport" -ge 1 ] && [ "$rport" -le 65535 ] \
    || die "remote _info reported an invalid sshPort — cannot build the data-plane alias"
  : "${rdev:=dev}"
  case "$rdev" in '' | -* | *[!a-zA-Z0-9_.-]*) die "remote _info reported an invalid devUser" ;; esac
  # Version drift is a warning, never fatal (control plane forwards to the remote's own CLI).
  if [ -n "$rver" ] && [ "$rver" != "$YARD_VERSION" ]; then
    warn "version drift: remote yard is $rver, this controller is $YARD_VERSION (forwarded commands run the remote's CLI)"
  fi

  local snip; snip="$(snip_path "$name")"
  local verb='Register'; [ "$refresh" = 1 ] && verb='Refresh'
  announce "$verb remote yard '$name' -> $dest" \
    "Atomically write the context $env_file (YARD_TYPE=remote, port $rport, user $rdev)." \
    "Generate the ProxyJump ssh alias 'yard-$name' with HostKeyAlias '$(hostkey_alias_for "$name")'." \
    "Authorize this controller's ssh public key in the remote yard (via 'yard _authorize')." \
    "Probe the complete data plane before reporting the context ready; roll back local files on failure." \
    "Lifecycle commands will forward to $dest; 'bind' stays disabled for remote yards." \
    "The remote owner host can read everything you explicitly sync into this yard; choose each source directory intentionally."
  proceed_or_die

  resolve_pubkey
  # Authorize FIRST, before writing any local state: if the remote yard is stopped this fails
  # here and leaves nothing partially registered (a clean retry, not a name clash on re-add).
  info "authorizing this controller's key in the remote yard…"
  printf '%s\n' "$PUBKEY" | remote_yard_cmd "$dest" "$ryard" _authorize \
    || {
      case "$rstate" in
        STOPPED | FROZEN) die "remote yard state is $rstate — start it on the owner host (ssh $dest -- yard ${ryard:+-Y $ryard }start), then retry" ;;
        *) die "could not authorize the controller key in the remote yard — check owner-host access and 'yard _authorize', then retry" ;;
      esac
    }

  local tx_rc=0
  if register_transaction "$env_file" "$name" "$dest" "$ryard" "$rport" "$rdev" "$IDENTITY"; then
    :
  else
    tx_rc=$?
    [ "$tx_rc" = 2 ] && [ "$REGISTER_TX_ERROR" = 'data-plane probe failed' ] \
      && diagnose_add_probe_failure "$name" "$dest" "$ryard" "$rport" "$json"
    [ "$tx_rc" = 3 ] && die "$REGISTER_TX_ERROR"
    die "$REGISTER_TX_ERROR (no local remote context was changed)"
  fi

  ok "context ready: $env_file"
  ok "ssh alias 'yard-$name' ready (~/.ssh/$(basename "$snip"); ProxyJump $dest)"
  show_yard_fingerprint "$name"
  write_cache "$name" "$json"
  echo
  ok "remote yard '$name' is ready."
  cat <<MSG

Use it like a local yard:
  $PROG -Y $name status          # forwarded to $dest (native prompts preserved)
  $PROG -Y $name sync <project-dir> && $PROG -Y $name code <project-dir>   # data plane via 'yard-$name'
  $PROG yards                     # $name now appears in the table

Security: the remote host can read everything explicitly synced into this yard; choose the project directory intentionally.
MSG
}

# --- remote remove -----------------------------------------------------------
cmd_remove() {
  local name=''
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes) shift ;;
      -*) die "remote remove: unknown option '$1'" ;;
      *) [ -z "$name" ] && { name="$1"; shift; } || die "remote remove: unexpected argument '$1'" ;;
    esac
  done
  [ -n "$name" ] || die "usage: $PROG remote remove <name>"
  yard_valid_name "$name" || die "invalid remote context name '$name'"
  local env_file; env_file="$(yard_env_file "$name" 2>/dev/null)" \
    || die "no such yard '$name' — see '$PROG yards'"
  # Only registry files that are actually remote may be removed here (guard local yards).
  [ "$(yard_env_val "$env_file" YARD_TYPE)" = remote ] \
    || die "'$name' is a LOCAL yard, not a remote one — use 'yard -Y $name teardown'"

  local snip; snip="$(snip_path "$name")"
  local statedir; statedir="$(state_dir_for_yard "$name")"
  local n; n="$(count_json_files "$statedir")"
  announce "Remove remote yard '$name'" \
    "Delete the context $env_file." \
    "Remove the ssh alias ~/.ssh/$(basename "$snip") and its Include line." \
    "Delete only the yard ssh trust pin '$(hostkey_alias_for "$name")'; endpoint keys and other contexts stay untouched." \
    "Drop the last-seen cache. The remote host and its yard are NOT touched." \
    "$n local project record(s) under $statedir are LEFT in place."
  proceed_or_die

  remove_hostkey_pin "$name"
  rm -f "$env_file"; ok "removed context $env_file"
  remove_alias "$name"
  rm -f "$(remote_cache_path "$name")" 2>/dev/null || true
  echo
  ok "remote yard '$name' unregistered (local project state kept)."
}

# --- remote list -------------------------------------------------------------
cmd_list() {
  for a in "$@"; do case "$a" in -y|--yes) ;; *) die "remote list takes no arguments" ;; esac; done
  local any=0
  printf '%s%-14s %-22s %-12s %-6s %s%s\n' "$C_HEAD" NAME DEST 'REMOTE YARD' PORT 'LAST PROBE' "$C_OFF"
  local name env_file dest ryard port c seen
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    env_file="$(yard_env_file "$name" 2>/dev/null)" || continue
    [ "$(yard_env_val "$env_file" YARD_TYPE)" = remote ] || continue
    any=1
    dest="$(yard_env_val "$env_file" REMOTE_DEST)"
    ryard="$(yard_env_val "$env_file" REMOTE_YARD)"
    port="$(yard_env_val "$env_file" REMOTE_SSH_PORT)"
    c="$(remote_cache_path "$name")"; seen='never'
    if [ -f "$c" ]; then
      local epoch; epoch="$(sed -n 1p "$c")"
      case "$epoch" in ''|*[!0-9]*) seen='?' ;; *) seen="$(age_human $(( $(date +%s) - epoch ))) ago" ;; esac
    fi
    printf '%-14s %-22s %-12s %-6s %s\n' "$name" "$dest" "${ryard:-<default>}" "${port:--}" "$seen"
  done < <(yard_registry_names)
  [ "$any" = 1 ] || info "no remote yards registered — add one with '$PROG remote add <name> <user@host>'"
}

sub="${1:-}"; shift || true
case "$sub" in
  add)        cmd_add "$@" ;;
  repair-key) cmd_repair_key "$@" ;;
  remove|rm)  cmd_remove "$@" ;;
  list|ls|'') cmd_list "$@" ;;
  -h|--help) _yard_help_and_exit ;;
  *) die "unknown 'remote' subcommand '$sub' (expected: add | repair-key | remove | list)" ;;
esac
