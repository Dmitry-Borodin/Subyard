#!/usr/bin/env bash
# project-clone.sh — Phase 7b: clone a git repo straight into the yard (mode 'git').
# Usage: project-clone.sh <git-url> [name] [@yard]   (@yard, like -Y, picks the target yard)
#   Clones <git-url> into /srv/workspaces/<id>/src in the yard, as the 'dev' user.
#   The clone runs inside the yard, so the YARD's network + credentials do it: a PUBLIC
#   url clones anonymously; a PRIVATE repo needs ssh-agent forwarding (FORWARD_SSH_AGENT=1
#   at setup) or a token in the https url. Mode 'git': the repo lives only in the yard,
#   addressed by id/name. id = <repo>-<sha256(url)[:8]>; state recorded like sync/bind.
# Remote yards (YARD_TYPE=remote): no local incus — reachability is an ssh probe and the
# in-yard `git clone` runs over the yard-<name> alias (as dev). A yard-side .subyard-meta.json
# is written on success (best-effort) for local AND remote yards.
# Operator-owned; no root. Config: config/incus.project.env + config/subyard.env + config/host.env.
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
# shellcheck source=scripts/state/transport.sh
. "$SCRIPT_DIR/state/transport.sh"
# shellcheck source=scripts/state/metadata.sh
. "$SCRIPT_DIR/state/metadata.sh"
# shellcheck source=scripts/lib/project-snapshot.sh
. "$SCRIPT_DIR/lib/project-snapshot.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_USER="${DEV_USER:-dev}"
DEV_UID="${DEV_UID:-1000}"
SSH_HOST="${SSH_HOST:-yard}"
PROFILES_DIR="$SCRIPT_DIR/../config/profiles"
PROJ=(--project "$INCUS_PROJECT")

project_snapshot_load
[ "$mode" = git ] || die "internal: clone adapter requires a git project snapshot"
url="$hostPath"
[ -n "$url" ] || die "internal: clone snapshot has no URL"
if [ "$target" != yard ]; then
  [ -r "$PROFILES_DIR/$target/profile.conf" ] || die "unknown --target '$target' — use 'yard' (L1) or a profile (L2): $(for d in "$PROFILES_DIR"/*/; do [ -r "$d/profile.conf" ] && basename "$d"; done | tr '\n' ' ')"
fi

yardDir="${yardPath%/src}"   # /srv/workspaces/<id>

# --- preflight: yard must be reachable ---------------------------------------
# Remote: probe the ssh alias (never incus). Local: incus daemon + instance RUNNING.
if yard_is_remote; then
  require_remote_reachable
else
  incus_preflight
  [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
    || die "yard is not running — start it: ${PROG:-yard} start"
fi

announce "yard clone — $name (mode git)" \
  "Clone : $url" \
  "Into  : $INSTANCE_NAME:$yardPath" \
  "Run target : $([ "$target" = yard ] && echo 'L1 — runs in the yard' || echo "L2 — box from profile '$target'")" \
  "Runs 'git clone' INSIDE the yard as '$DEV_USER' (yard's network + creds; no host copy)." \
  "Publish the validated project record through the Go control plane."
proceed_or_die

# Fresh dir owned by dev, then clone as dev (uses dev's in-yard git identity/creds). Remote:
# run the same three steps over the yard-<name> ssh alias (which logs in as dev), never incus.
if yard_is_remote; then
  ssh "$SSH_HOST" -- rm -rf "$yardDir" >/dev/null 2>&1 || true
  ssh "$SSH_HOST" -- install -d "$yardDir" \
    || die "could not create $yardDir in the remote yard"
  info "cloning $url → $SSH_HOST:$yardPath …"
  ssh "$SSH_HOST" -- git clone "$url" "$yardPath" \
    || die "git clone failed (private repo? enable ssh-agent forwarding at setup, or use an https token url)"
else
  incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- rm -rf "$yardDir" >/dev/null 2>&1 || true
  incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- install -d -o "$DEV_UID" -g "$DEV_UID" "$yardDir" \
    || die "could not create $yardDir in the yard"
  info "cloning $url → $INSTANCE_NAME:$yardPath …"
  incus exec "$INSTANCE_NAME" "${PROJ[@]}" --user "$DEV_UID" --group "$DEV_UID" --env HOME="/home/$DEV_USER" -- \
    git clone "$url" "$yardPath" \
    || die "git clone failed (private repo? enable ssh-agent forwarding at setup, or use an https token url)"
fi

# Go publishes controller and remote-owner state after this physical adapter returns success.
write_yard_meta "$id" "$name" git "$target"
ok "cloned $name → $yardPath (target $target)"
info "id: $id"
cat <<MSG

In the yard at: $yardPath   (mode git; address it by name '$name' or id '$id')
  ${PROG:-yard} list                 # see it
  ${PROG:-yard} ssh -- ls $yardPath  # browse it in the yard
MSG
