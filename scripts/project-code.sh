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
command -v incus >/dev/null 2>&1 || die "incus not found — run 'yard setup' first"
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it: yard up"
incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx ssh \
  || die "SSH access not set up — run 'yard setup' (or scripts/07-ssh-access.sh)"

uri="vscode-remote://ssh-remote+$host$yardPath"
if command -v code >/dev/null 2>&1; then
  info "opening $host:$yardPath in VS Code …"
  exec code --folder-uri "$uri"
else
  warn "the 'code' CLI is not on PATH — open it manually:"
  printf '  code --folder-uri "%s"\n' "$uri"
  printf '  (or VS Code → Remote-SSH: Connect to Host → %s, then open %s)\n' "$host" "$yardPath"
fi
