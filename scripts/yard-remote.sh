#!/usr/bin/env bash
# yard-remote.sh — manage REMOTE yards: an external host running Subyard, driven as if local.
#   remote add <name> <user@host|ssh-alias> [--yard <remote-yard-name>]
#       Probe the host's `yard _info` over ssh, register a machine-local context
#       (~/.config/subyard/yards/<name>.env, YARD_TYPE=remote), generate the ProxyJump ssh
#       alias 'yard-<name>' (data plane: code/ssh/sync), and authorize this controller's
#       public key in the remote yard. Lifecycle commands then FORWARD to the owner host
#       (`yard -Y <name> status|start|…`), data-plane commands go straight into the yard.
#   remote remove <name>    drop the context + its ssh alias (project state is left in place).
#   remote list             one row per remote yard: name, dest, remote yard, port, last seen.
# Trust: an account on the remote host = full trust of it. No secrets/keys are copied there;
# host secrets and staging/qa env live on the owner host. Agent-forwarding is OFF by default.
# Config: config/host.env (SUBYARD_HOME/SUBYARD_CONFIG_HOME) + the registry helpers in lib.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

PROG="${PROG:-yard}"                             # the dispatcher does not export it; user-facing name
REG_DIR="${SUBYARD_CONFIG_HOME:-$SUBYARD_OPERATOR_HOME/.config/subyard}/yards"
SSH_DIR="$HOME/.ssh"
CM_DIR="$SUBYARD_HOME/ssh"                       # ControlPath sockets + known_hosts live here
CONNECT_TIMEOUT="${SUBYARD_REMOTE_TIMEOUT:-10}"  # add-time probe budget (yards/status use 2s)

# JSON scrapers (json_str/json_num), the env-file reader (yard_env_val) and age_human live in
# lib.sh — used below unqualified.

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

# Best-effort host-key fingerprint for the operator to eyeball on first contact. Resolves the
# dest (which may be an ssh-alias) to hostname/port via `ssh -G`, then reads the recorded key.
show_fingerprint() {   # <dest>
  local dest="$1" hn port target fp
  hn="$(ssh -G "$dest" 2>/dev/null | awk '$1=="hostname"{print $2; exit}')" || hn=''
  port="$(ssh -G "$dest" 2>/dev/null | awk '$1=="port"{print $2; exit}')" || port='22'
  [ -n "$hn" ] || { info "host key recorded (accept-new)"; return 0; }
  target="$hn"; [ "${port:-22}" != 22 ] && target="[$hn]:$port"
  fp="$(ssh-keygen -F "$target" -l 2>/dev/null | grep -v '^#' | head -n1)" || fp=''
  if [ -n "$fp" ]; then info "host key ($hn): $fp"; else info "host key for $hn recorded (accept-new)"; fi
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
# last-good _info JSON + epoch cache lives at remote_cache_path (lib.sh)

# Write the per-remote-yard ssh alias via 07-ssh-access.sh's Include mechanism (idempotent, one
# Include line per snippet, prepended so it applies before any Host blocks). Data plane only:
# ProxyJump through the owner host to 127.0.0.1:<port> inside the yard. ForwardAgent OFF (the
# agent socket must never land on the remote host); ControlMaster reuses one connection.
write_alias() {   # <name> <dest> <port> <devuser> <identity>
  local name="$1" dest="$2" port="$3" devuser="$4" identity="$5"
  local snip; snip="$(snip_path "$name")"; local snip_name; snip_name="$(basename "$snip")"
  local known="$CM_DIR/known_hosts"
  install -d -m 700 "$SSH_DIR" "$CM_DIR"
  cat > "$snip" <<EOF
# Managed by Subyard (scripts/yard-remote.sh) — regenerated on 'yard remote add'; do not edit.
Host yard-$name
    HostName 127.0.0.1
    Port $port
    User $devuser
    ProxyJump $dest
    IdentityFile $identity
    IdentitiesOnly yes
    ForwardAgent no
    ControlMaster auto
    ControlPath $CM_DIR/cm-%r@%h:%p
    ControlPersist 60s
    StrictHostKeyChecking accept-new
    UserKnownHostsFile $known
EOF
  chmod 600 "$snip"
  local cfg="$SSH_DIR/config"; touch "$cfg"; chmod 600 "$cfg"
  if ! grep -qxF "Include $snip_name" "$cfg"; then
    { printf 'Include %s\n' "$snip_name"; cat "$cfg"; } > "$cfg.tmp" && mv -f "$cfg.tmp" "$cfg"
  fi
  ok "ssh alias 'yard-$name' ready (~/.ssh/$snip_name; ProxyJump $dest)"
}

# Drop this remote yard's ssh alias + its Include line (idempotent).
remove_alias() {   # <name>
  local name="$1" snip; snip="$(snip_path "$name")"; local snip_name; snip_name="$(basename "$snip")"
  local cfg="$SSH_DIR/config"
  [ -f "$snip" ] && { rm -f "$snip"; ok "removed ssh alias file ~/.ssh/$snip_name"; }
  if [ -f "$cfg" ] && grep -qxF "Include $snip_name" "$cfg"; then
    grep -vxF "Include $snip_name" "$cfg" > "$cfg.tmp" && mv -f "$cfg.tmp" "$cfg"
    ok "removed the Include line from ~/.ssh/config"
  fi
}

# Persist the last good probe so `yard yards`/`status --all` show a last-seen state when the
# host is briefly unreachable. Format: line 1 = epoch seconds, line 2 = the _info JSON.
write_cache() {   # <name> <json>
  local name="$1" json="$2" c; c="$(remote_cache_path "$name")"
  install -d -m 700 "$SUBYARD_HOME" 2>/dev/null || return 0
  { printf '%s\n' "$(date +%s)"; printf '%s\n' "$json"; } > "$c.tmp" && mv -f "$c.tmp" "$c"
}

# --- remote add --------------------------------------------------------------
cmd_add() {
  local name='' dest='' ryard=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --yard) [ $# -ge 2 ] || die "remote add: --yard needs a name"; ryard="$2"; shift 2 ;;
      --yard=*) ryard="${1#--yard=}"; shift ;;
      -y|--yes) shift ;;                       # consumed by lib.sh; ignore positionally
      -*) die "remote add: unknown option '$1'" ;;
      *) if [ -z "$name" ]; then name="$1"; elif [ -z "$dest" ]; then dest="$1";
         else die "remote add: unexpected argument '$1'"; fi; shift ;;
    esac
  done
  [ -n "$name" ] && [ -n "$dest" ] || die "usage: $PROG remote add <name> <user@host|ssh-alias> [--yard <remote-yard>]"
  _yard_valid_name "$name" \
    || die "invalid yard name '$name' (allowed: lowercase letters, digits, '-', '_'; must start with a letter or digit)"
  [ -n "$ryard" ] && { _yard_valid_name "$ryard" || die "invalid --yard name '$ryard'"; }
  # Refuse to shadow any existing registry name (a local yard, or an already-registered remote).
  local existing
  while IFS= read -r existing; do
    [ "$existing" = "$name" ] && die "a yard named '$name' already exists — pick another name (or '$PROG remote remove $name' first)"
  done < <(yard_registry_names)

  info "probing $dest (yard ${ryard:-<default>} _info)…"
  local json
  json="$(remote_yard_cmd "$dest" "$ryard" _info 2>/dev/null)" \
    || die "cannot reach '$dest' or run 'yard _info' there — is Subyard installed and is your ssh access working? (try: ssh $dest -- yard _info)"
  case "$json" in
    '{'*'}') ;;   # a flat JSON object as _info emits
    *) die "'$dest' answered but not with yard _info JSON — check the remote yard's version (got: ${json:0:60})" ;;
  esac
  show_fingerprint "$dest"

  local rport rdev rver
  rport="$(json_num "$json" sshPort)"; rdev="$(json_str "$json" devUser)"; rver="$(json_str "$json" version)"
  [ -n "$rport" ] || die "remote _info reported no sshPort — cannot build the data-plane alias"
  : "${rdev:=dev}"
  # Version drift is a warning, never fatal (control plane forwards to the remote's own CLI).
  if [ -n "$rver" ] && [ "$rver" != "$YARD_VERSION" ]; then
    warn "version drift: remote yard is $rver, this controller is $YARD_VERSION (forwarded commands run the remote's CLI)"
  fi

  local env_file="$REG_DIR/$name.env"
  local snip; snip="$(snip_path "$name")"
  announce "Register remote yard '$name' -> $dest" \
    "Write the context $env_file (YARD_TYPE=remote, port $rport, user $rdev)." \
    "Generate the ProxyJump ssh alias 'yard-$name' in ~/.ssh/$(basename "$snip")." \
    "Authorize this controller's ssh public key in the remote yard (via 'yard _authorize')." \
    "Lifecycle commands will forward to $dest; 'bind' stays disabled for remote yards."
  proceed_or_die

  resolve_pubkey
  # Authorize FIRST, before writing any local state: if the remote yard is stopped this fails
  # here and leaves nothing partially registered (a clean retry, not a name clash on re-add).
  info "authorizing this controller's key in the remote yard…"
  printf '%s\n' "$PUBKEY" | remote_yard_cmd "$dest" "$ryard" _authorize \
    || die "could not authorize the key remotely — the remote yard may be stopped (start it: ssh $dest -- yard ${ryard:+-Y $ryard }start), then re-run '$PROG remote add $name $dest'"

  install -d -m 700 "$REG_DIR"
  cat > "$env_file" <<EOF
# Subyard remote yard '$name' — generated by 'yard remote add' on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Machine-local (do NOT commit). Reached over SSH: lifecycle commands forward to the owner host,
# data-plane (code/ssh/sync) goes straight into the yard via the 'yard-$name' ProxyJump alias.
YARD_TYPE=remote
REMOTE_DEST=$dest
REMOTE_YARD=$ryard
REMOTE_SSH_PORT=$rport
REMOTE_DEV_USER=$rdev
# Mirror the port for the local context view; force agent-forwarding off for a remote yard
# (the agent socket must never end up on someone else's host). Add overrides below if needed.
SSH_PORT=$rport
FORWARD_SSH_AGENT=0
EOF
  chmod 600 "$env_file"
  ok "registered context: $env_file"

  write_alias "$name" "$dest" "$rport" "$rdev" "$IDENTITY"
  write_cache "$name" "$json"
  echo
  ok "remote yard '$name' is ready."
  cat <<MSG

Use it like a local yard:
  $PROG -Y $name status          # forwarded to $dest (native prompts preserved)
  $PROG -Y $name sync . && $PROG -Y $name code .   # data plane via 'yard-$name'
  $PROG yards                     # $name now appears in the table
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
    "Drop the last-seen cache. The remote host and its yard are NOT touched." \
    "$n local project record(s) under $statedir are LEFT in place."
  proceed_or_die

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
  add)    cmd_add "$@" ;;
  remove|rm) cmd_remove "$@" ;;
  list|ls|'') cmd_list "$@" ;;
  -h|--help) _yard_help_and_exit ;;
  *) die "unknown 'remote' subcommand '$sub' (expected: add | remove | list)" ;;
esac
