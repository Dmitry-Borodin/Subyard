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
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_USER="${DEV_USER:-dev}"
DEV_UID="${DEV_UID:-1000}"
SSH_HOST="${SSH_HOST:-yard}"
PROFILES_DIR="$SCRIPT_DIR/../config/profiles"
PROJ=(--project "$INCUS_PROJECT")

# --- parse args --------------------------------------------------------------
# --target yard|<profile>: where the project runs (L1 yard vs L2 profile box). Default yard.
url=""; name=""; target="yard"; at_yard=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target)   target="${2:?--target needs yard|<profile>}"; shift ;;
    --target=*) target="${1#*=}" ;;
    -y | --yes) ;;  # handled by lib.sh (ASSUME_YES)
    @?*)        at_yard="${1#@}" ;;  # trailing `@<yard>` — target yard (equivalent to -Y)
    -*)         die "unknown option '$1'" ;;
    *)          if [ -z "$url" ]; then url="$1"; elif [ -z "$name" ]; then name="$1"; else die "too many arguments"; fi ;;
  esac
  shift
done
[ -n "$url" ] || die "usage: ${PROG:-yard} clone <git-url> [name] [--target yard|<profile>]"
if [ "$target" != yard ]; then
  [ -r "$PROFILES_DIR/$target/profile.conf" ] || die "unknown --target '$target' — use 'yard' (L1) or a profile (L2): $(for d in "$PROFILES_DIR"/*/; do [ -r "$d/profile.conf" ] && basename "$d"; done | tr '\n' ' ')"
fi

# --- derive name + id (from the url; no host path for a clone) ----------------
[ -n "$name" ] || { name="$(basename -- "$url")"; name="${name%.git}"; }
sname="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-')"
hash="$(printf '%s' "$url" | sha256sum | cut -c1-8)"
id="$sname-$hash"
yardPath="$(yard_path_for "$id")"
yardDir="${yardPath%/src}"   # /srv/workspaces/<id>

# Route to the target yard: `@<yard>` picks it; else re-exec to whichever yard already holds
# this url; else stay in the current context. (See route_sync_target.)
route_sync_target "$id" "$at_yard"

state_exists "$id" \
  && die "'$name' is already in the yard (id $id) — remove it first: ${PROG:-yard} remove $name"

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
  "Record machine-local state in $(state_file "$id")."
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

# As with remote sync, owner-host registration is part of completion and happens before this
# controller publishes its local record, keeping an interrupted operation safely rerunnable.
write_yard_meta "$id" "$name" git "$target"
if yard_is_remote; then
  remote_owner_project_upsert "$id" "$name" git "$target" \
    || die "project cloned, but the owner-host registry was not updated; re-run the same clone command"
fi
state_write "$id" "$name" "$url" "$yardPath" git "$SSH_HOST"
state_set "$id" target "$target"
ok "cloned $name → $yardPath (target $target)"
info "id: $id"
cat <<MSG

In the yard at: $yardPath   (mode git; address it by name '$name' or id '$id')
  ${PROG:-yard} list                 # see it
  ${PROG:-yard} ssh -- ls $yardPath  # browse it in the yard
MSG
