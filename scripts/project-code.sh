#!/usr/bin/env bash
# project-code.sh — open an imported project in VS Code via Remote-SSH into the yard.
# Usage: project-code.sh [path]   (default '.')
# Resolves the project's machine-local state (yardPath + sshHost) and launches
# `code` against vscode-remote://ssh-remote+<host><yardPath>. From there: VS Code
# "Dev Containers: Reopen in Container" builds the agent machine. Operator; no root.
# Config: config/incus.project.env + config/subyard.env.
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
SSH_HOST="${SSH_HOST:-yard}"
PROJ=(--project "$INCUS_PROJECT")

path="."
for a in "$@"; do
  case "$a" in -y|--yes) ;; -*) die "unknown option '$a'" ;; *) path="$a" ;; esac
done
[ -e "$path" ] || die "no such path: $path"

id="$(project_id "$path")"
state_exists "$id" || die "'$(basename "$(realpath "$path")")' is not imported — run: ${PROG:-yard} import $path"
yardPath="$(state_get "$id" yardPath)"
host="$(state_get "$id" sshHost)"; host="${host:-$SSH_HOST}"

# Yard must be up, and SSH access must be set up (Remote-SSH needs the proxy + key).
incus_preflight code
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it: yard up"
incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx ssh \
  || die "SSH access not set up — run 'yard setup' (or scripts/07-ssh-access.sh)"

uri="vscode-remote://ssh-remote+$host$yardPath"
if command -v code >/dev/null 2>&1; then
  # Remote-SSH must be installed, or `code` gets an ssh-remote:// URI it can't handle and
  # silently no-ops (no SSH connection reaches the yard, no server installs). Block early
  # with the fix. Act only on a KNOWN-missing extension: if we can't enumerate (empty
  # list), proceed rather than false-alarm.
  exts="$(code --list-extensions 2>/dev/null || true)"
  if [ -n "$exts" ] && ! printf '%s\n' "$exts" | grep -qixF ms-vscode-remote.remote-ssh; then
    warn "VS Code lacks the Remote-SSH extension — required to open the yard over SSH."
    # Installing is a modifying action: ask first (auto-yes under -y/--yes). On 'no',
    # don't proceed to a doomed `code` launch — say plainly why it can't connect.
    if confirm "Install it now (code --install-extension ms-vscode-remote.remote-ssh)?"; then
      code --install-extension ms-vscode-remote.remote-ssh \
        || die "install failed — run it manually: code --install-extension ms-vscode-remote.remote-ssh"
      ok "Remote-SSH installed"
    else
      die "without Remote-SSH, VS Code can't connect to the yard — install it and re-run 'yard code'."
    fi
  fi
  info "opening $host:$yardPath in VS Code …"
  exec code --folder-uri "$uri"
else
  warn "the 'code' CLI is not on PATH — open it manually:"
  printf '  code --folder-uri "%s"\n' "$uri"
  printf '  (or VS Code → Remote-SSH: Connect to Host → %s, then open %s)\n' "$host" "$yardPath"
fi
