#!/usr/bin/env bash
# 07-ssh-access.sh — give the operator SSH into the yard for VS Code and data transfer
# Remote-SSH (`yard code`) work. Three idempotent steps, all operator-owned (no root):
#   1. an Incus proxy device  host 127.0.0.1:$SSH_PORT -> yard:22  (loopback only),
#   2. the operator's public key in the yard user's authorized_keys,
#   3. a 'Host $SSH_HOST' entry in ~/.ssh (via an Include — your config is not clobbered).
# Key source: $SUBYARD_SSH_PUBKEY, else ~/.ssh/id_*.pub, else a dedicated
# key is generated under ~/.subyard/ssh. Config: config/incus.project.env + subyard.env.
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

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_USER="${DEV_USER:-dev}"
SSH_HOST="${SSH_HOST:-yard}"
SSH_PORT="${SSH_PORT:-2222}"
# Opt-in (default off): forward the host ssh-agent so in-yard git over SSH uses your
# host keys without copying any private key into the yard.
FORWARD_SSH_AGENT="${FORWARD_SSH_AGENT:-0}"
PROJ=(--project "$INCUS_PROJECT")
device_exists() { incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx "$1"; }
dev_get() { incus config device get "$INSTANCE_NAME" "$1" "$2" "${PROJ[@]}" 2>/dev/null || true; }

# --- preconditions -----------------------------------------------------------
incus_preflight
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "instance '$INSTANCE_NAME' missing — run '$(yard_cmd_hint) init' first"
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it: $(yard_cmd_hint) start"

fwd_note=()
[ "$FORWARD_SSH_AGENT" = 1 ] && fwd_note=("Enable ssh-agent forwarding for '$SSH_HOST' (no private key enters the yard).")
announce "yard SSH access ($SSH_HOST)" \
  "Add an Incus proxy device: host 127.0.0.1:$SSH_PORT -> yard:22 (loopback only)." \
  "Authorize your SSH public key for '$DEV_USER' in the yard." \
  "Add a 'Host $SSH_HOST' entry to ~/.ssh (via an Include; your config is not rewritten)." \
  ${fwd_note[@]+"${fwd_note[@]}"}
proceed_or_die

# --- 1. resolve the operator's public key ------------------------------------
PUBKEY_FILE=""
if [ -n "${SUBYARD_SSH_PUBKEY:-}" ]; then
  PUBKEY_FILE="$SUBYARD_SSH_PUBKEY"
else
  for k in id_ed25519 id_ecdsa id_rsa; do
    [ -f "$HOME/.ssh/$k.pub" ] && { PUBKEY_FILE="$HOME/.ssh/$k.pub"; break; }
  done
fi
if [ -z "$PUBKEY_FILE" ]; then
  keydir="$SUBYARD_HOME/ssh"; install -d -m 700 "$keydir"
  [ -f "$keydir/id_ed25519" ] || {
    ssh-keygen -t ed25519 -N "" -C "subyard-$SSH_HOST" -f "$keydir/id_ed25519" >/dev/null
    info "no key found — generated a dedicated one: $keydir/id_ed25519"
  }
  PUBKEY_FILE="$keydir/id_ed25519.pub"
fi
[ -r "$PUBKEY_FILE" ] || die "cannot read public key: $PUBKEY_FILE"
PUBKEY="$(cat "$PUBKEY_FILE")"
IDENTITY="${PUBKEY_FILE%.pub}"
ok "public key: $PUBKEY_FILE"

# --- 2. proxy device (idempotent) --------------------------------------------
echo "SSH proxy:"
if device_exists ssh; then
  if [ "$(dev_get ssh type)" = proxy ] \
    && [ "$(dev_get ssh listen)" = "tcp:127.0.0.1:$SSH_PORT" ] \
    && [ "$(dev_get ssh connect)" = tcp:127.0.0.1:22 ]; then
    ok "proxy device 'ssh' already attached"
  else
    warn "proxy device 'ssh' drifted — re-attaching on 127.0.0.1:$SSH_PORT"
    incus config device remove "$INSTANCE_NAME" ssh "${PROJ[@]}" >/dev/null
  fi
fi
if ! device_exists ssh; then
  incus config device add "$INSTANCE_NAME" ssh proxy "${PROJ[@]}" \
    listen="tcp:127.0.0.1:$SSH_PORT" connect=tcp:127.0.0.1:22 bind=host >/dev/null
  ok "added proxy 127.0.0.1:$SSH_PORT -> yard:22"
fi

# --- 3. authorize the key for dev in the yard (idempotent) -------------------
echo "Authorized key:"
incus exec "$INSTANCE_NAME" "${PROJ[@]}" --env PUBKEY="$PUBKEY" --env DEV_USER="$DEV_USER" -- sh -eu -c '
  home="$(getent passwd "$DEV_USER" | cut -d: -f6)"
  install -d -m 700 -o "$DEV_USER" -g "$DEV_USER" "$home/.ssh"
  ak="$home/.ssh/authorized_keys"; touch "$ak"
  grep -qxF "$PUBKEY" "$ak" || printf "%s\n" "$PUBKEY" >> "$ak"
  chmod 600 "$ak"; chown "$DEV_USER":"$DEV_USER" "$ak"
' || die "could not authorize the key in the yard"
ok "$DEV_USER@$SSH_HOST authorized for your key"

# --- 4. ~/.ssh Host entry via an Include (does not rewrite your config) -------
echo "SSH client config:"
sshdir="$HOME/.ssh"; install -d -m 700 "$sshdir"
# Per-yard snippet: the default yard keeps ~/.ssh/subyard.config (byte-identical); a named
# yard gets its own ~/.ssh/subyard-<name>.config so several yards' Host blocks never collide
# and teardown of one removes only that file. Its Include line is added per file (below).
snip="$sshdir/subyard${YARD_NAME:+-$YARD_NAME}.config"
snip_name="$(basename "$snip")"
# Shared across yards, but host-key entries are keyed by [127.0.0.1]:<port> and each yard
# has a unique port, so entries never collide — one known_hosts is correct and intended.
known="$SUBYARD_HOME/ssh/known_hosts"
install -d -m 700 "$SUBYARD_HOME/ssh"   # so ssh can record the yard's host key
# Opt-in agent forwarding: lets in-yard `git pull/push` over SSH use the host keys
# held by your ssh-agent, without any private key ever entering the yard.
fwd=""; [ "$FORWARD_SSH_AGENT" = 1 ] && fwd=$'\n    ForwardAgent yes'
cat > "$snip" <<EOF
# Managed by Subyard (scripts/07-ssh-access.sh) — regenerated on setup; do not edit.
Host $SSH_HOST
    HostName 127.0.0.1
    Port $SSH_PORT
    User $DEV_USER
    IdentityFile $IDENTITY
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile $known$fwd
EOF
chmod 600 "$snip"
cfg="$sshdir/config"; touch "$cfg"; chmod 600 "$cfg"
# Prepend this yard's Include once (must precede Host blocks to apply globally). One line per
# snippet file, idempotent: each yard has its own `Include subyard[-<name>].config`.
if ! grep -qxF "Include $snip_name" "$cfg"; then
  { printf 'Include %s\n' "$snip_name"; cat "$cfg"; } > "$cfg.tmp" && mv -f "$cfg.tmp" "$cfg"
fi
ok "ssh Host '$SSH_HOST' ready (~/.ssh/$snip_name)"

echo
ok "SSH access ready."
cat <<MSG

Verify:
  ssh $SSH_HOST -- hostname        # logs into the yard as $DEV_USER
  yard code .                      # VS Code Remote-SSH into the yard
MSG
