#!/usr/bin/env bash
# 08-git-identity.sh — give the in-yard 'dev' user a git identity, so commits made
# inside the yard are attributed (not "unknown <dev@yard>"). Operator-owned (no root).
# Source of the identity, in order of precedence:
#   1. $SUBYARD_HOME/gitconfig          — a full drop-in; copied verbatim as dev's ~/.gitconfig
#   2. $GIT_USER_NAME / $GIT_USER_EMAIL — explicit override (config/subyard.env or env)
#   3. the host's `git config --global user.name/email` — inherited at setup time
# No keys or secrets — name/email only. Idempotent: re-running just rewrites the file.
# Config: config/incus.project.env + config/subyard.env + config/host.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_USER="${DEV_USER:-dev}"
PROJ=(--project "$INCUS_PROJECT")

# --- preconditions -----------------------------------------------------------
incus_preflight
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it: $(yard_cmd_hint) start"

# --- resolve identity on the host --------------------------------------------
dropin="$SUBYARD_HOME/gitconfig"
if [ -r "$dropin" ]; then
  src="drop-in $dropin"
else
  name="${GIT_USER_NAME:-}"; email="${GIT_USER_EMAIL:-}"
  [ -n "$name" ]  || name="$(git config --global user.name  2>/dev/null || true)"
  [ -n "$email" ] || email="$(git config --global user.email 2>/dev/null || true)"
  src="name/email"
fi

if [ ! -r "$dropin" ] && [ -z "${name:-}" ] && [ -z "${email:-}" ]; then
  warn "no git identity found (no $dropin, no GIT_USER_* set, no host global git config)."
  info "commits made in the yard would be unattributed. Set GIT_USER_NAME/GIT_USER_EMAIL"
  info "in config/subyard.env (or git config --global … on the host), then re-run."
  exit 0
fi

announce "yard git identity ($DEV_USER@$INSTANCE_NAME)" \
  "Write $DEV_USER's ~/.gitconfig in the yard from: $src." \
  "No SSH/GPG keys are written — identity is name/email only."
proceed_or_die

# --- apply inside the yard ---------------------------------------------------
if [ -r "$dropin" ]; then
  incus file push "$dropin" "$INSTANCE_NAME/home/$DEV_USER/.gitconfig" \
    "${PROJ[@]}" --uid 0 --gid 0 --mode 0644 >/dev/null
  incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- chown "$DEV_USER:$DEV_USER" "/home/$DEV_USER/.gitconfig"
  ok "installed $DEV_USER's ~/.gitconfig from $dropin"
else
  incus exec "$INSTANCE_NAME" "${PROJ[@]}" \
    --env DEV_USER="$DEV_USER" --env GN="${name:-}" --env GE="${email:-}" -- sh -eu -c '
      home="$(getent passwd "$DEV_USER" | cut -d: -f6)"
      run() { su -s /bin/sh "$DEV_USER" -c "$1"; }
      [ -n "$GN" ] && run "git config --global user.name  \"$GN\""
      [ -n "$GE" ] && run "git config --global user.email \"$GE\""
      chown "$DEV_USER:$DEV_USER" "$home/.gitconfig"
    ' || die "could not set git identity in the yard"
  ok "set $DEV_USER git identity${name:+: $name}${email:+ <$email>}"
fi

# Trust bind-mounted repos: idmapped host binds present a mismatched owner uid in the yard, so git
# refuses with "dubious ownership". (After the identity write so a drop-in can't drop it.) Idempotent.
incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- \
  su -s /bin/sh "$DEV_USER" -c "git config --global --replace-all safe.directory '*'" 2>/dev/null \
  && ok "git: trust bind-mounted repos (safe.directory='*') for $DEV_USER" \
  || warn "could not set git safe.directory for $DEV_USER"

echo
ok "git identity ready."
cat <<MSG

Verify:
  yard shell -- git config --global --list | grep -E 'user\.(name|email)'
MSG
