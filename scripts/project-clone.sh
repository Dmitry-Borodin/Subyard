#!/usr/bin/env bash
# project-clone.sh — Phase 7b: clone a git repo straight into the yard (mode 'git').
# Usage: project-clone.sh <git-url> [name]
#   Clones <git-url> into /srv/workspaces/<id>/src in the yard, as the 'dev' user.
#   The clone runs inside the yard, so the YARD's network + credentials do it: a PUBLIC
#   url clones anonymously; a PRIVATE repo needs ssh-agent forwarding (FORWARD_SSH_AGENT=1
#   at setup) or a token in the https url. No host copy — this is mode 'git' (unlike
#   import's 'sync'/'bind'); the project is addressed by id/name, not a host path.
#   id = <repo>-<sha256(url)[:8]>; machine-local state recorded like import.
# Operator-owned; no root. Config: config/incus.project.env + config/subyard.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

for cfg in incus.project.env subyard.env; do
  f="$SCRIPT_DIR/../config/$cfg"
  # shellcheck disable=SC1090
  [ -r "$f" ] && . "$f"
done
INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_USER="${DEV_USER:-dev}"
DEV_UID="${DEV_UID:-1000}"
SSH_HOST="${SSH_HOST:-yard}"
PROJ=(--project "$INCUS_PROJECT")

# --- parse args --------------------------------------------------------------
url=""; name=""
for a in "$@"; do
  case "$a" in
    -y | --yes) ;;  # handled by lib.sh (ASSUME_YES)
    -*)         die "unknown option '$a'" ;;
    *)          if [ -z "$url" ]; then url="$a"; elif [ -z "$name" ]; then name="$a"; else die "too many arguments"; fi ;;
  esac
done
[ -n "$url" ] || die "usage: ${PROG:-yard} clone <git-url> [name]"

# --- derive name + id (from the url; no host path for a clone) ----------------
[ -n "$name" ] || { name="$(basename -- "$url")"; name="${name%.git}"; }
sname="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-')"
hash="$(printf '%s' "$url" | sha256sum | cut -c1-8)"
id="$sname-$hash"
yardPath="$(yard_path_for "$id")"
yardDir="${yardPath%/src}"   # /srv/workspaces/<id>

state_exists "$id" \
  && die "'$name' is already in the yard (id $id) — remove it first: ${PROG:-yard} remove $name"

# --- preflight: yard must be running -----------------------------------------
command -v incus >/dev/null 2>&1 || die "incus not found — run 'yard setup' first"
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it: ${PROG:-yard} up"

announce "yard clone — $name (mode git)" \
  "Clone : $url" \
  "Into  : $INSTANCE_NAME:$yardPath" \
  "Runs 'git clone' INSIDE the yard as '$DEV_USER' (yard's network + creds; no host copy)." \
  "Record machine-local state in $(state_file "$id")."
proceed_or_die

# Fresh dir owned by dev, then clone as dev (uses dev's in-yard git identity/creds).
incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- rm -rf "$yardDir" >/dev/null 2>&1 || true
incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- install -d -o "$DEV_UID" -g "$DEV_UID" "$yardDir" \
  || die "could not create $yardDir in the yard"
info "cloning $url → $INSTANCE_NAME:$yardPath …"
incus exec "$INSTANCE_NAME" "${PROJ[@]}" --user "$DEV_UID" --group "$DEV_UID" --env HOME="/home/$DEV_USER" -- \
  git clone "$url" "$yardPath" \
  || die "git clone failed (private repo? enable ssh-agent forwarding at setup, or use an https token url)"

state_write "$id" "$name" "$url" "$yardPath" git "$SSH_HOST"
ok "cloned $name → $yardPath"
info "id: $id"
cat <<MSG

In the yard at: $yardPath   (mode git; address it by name '$name' or id '$id')
  ${PROG:-yard} list                 # see it
  ${PROG:-yard} ssh -- ls $yardPath  # browse it in the yard
MSG
