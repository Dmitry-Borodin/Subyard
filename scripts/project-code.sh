#!/usr/bin/env bash
# project-code.sh — open an in-yard project in VS Code via Remote-SSH into the yard.
# Usage: project-code.sh [path]   (default '.')
# Resolves the project's machine-local state (yardPath + sshHost) and launches
# `code` against vscode-remote://ssh-remote+<host><yardPath>. From there: VS Code
# "Dev Containers: Reopen in Container" builds the agent container. Operator; no root.
# Config: config/incus.project.env + config/subyard.env + config/host.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
SSH_HOST="${SSH_HOST:-yard}"
DEV_USER="${DEV_USER:-dev}"
DEV_UID="${DEV_UID:-1000}"
DEV_GID="${DEV_GID:-1000}"
# Coding agents to recommend (П1 step 3) when the workspace opens — space-separated
# marketplace IDs; override in config/subyard.env. Note: "Codex – OpenAI's coding agent"
# ships as openai.chatgpt; opencode is sst-dev.opencode; Claude Code is anthropic.claude-code.
CODE_RECOMMENDED_EXTENSIONS="${CODE_RECOMMENDED_EXTENSIONS:-anthropic.claude-code openai.chatgpt sst-dev.opencode}"
PROJ=(--project "$INCUS_PROJECT")

path="."
for a in "$@"; do
  case "$a" in -y|--yes) ;; -*) die "unknown option '$a'" ;; *) path="$a" ;; esac
done
[ -e "$path" ] || die "no such path: $path"

id="$(project_id "$path")"
state_exists "$id" || die "'$(basename "$(realpath "$path")")' is not in the yard — run: ${PROG:-yard} sync $path (or: bind $path)"
yardPath="$(state_get "$id" yardPath)"
host="$(state_get "$id" sshHost)"; host="${host:-$SSH_HOST}"
name="$(state_get "$id" name)"; name="${name:-$(basename "$(realpath "$path")")}"

# Yard must be up, and SSH access must be set up (Remote-SSH needs the proxy + key).
incus_preflight code
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it: yard start"
incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx ssh \
  || die "SSH access not set up — run 'yard init' (or scripts/07-ssh-access.sh)"

# VS Code labels a window by its leaf folder — for us that's the useless "src". Write a
# tiny .code-workspace that names the (absolute) src path with the project, so the title
# and Explorer read e.g. "Subyard", and recommends the in-yard coding agents. It lives in
# dev's HOME (always dev-writable — some workspace wrappers are root-owned) and is opened
# with --file-uri. JSON is single-line and every string value is escaped, so a quirky
# project name or extension id can't break it.
wsfile="/home/$DEV_USER/.subyard/workspaces/${name//[^A-Za-z0-9._-]/_}.code-workspace"
esc_name="${name//\\/\\\\}";    esc_name="${esc_name//\"/\\\"}"
esc_path="${yardPath//\\/\\\\}"; esc_path="${esc_path//\"/\\\"}"
recs=""   # JSON array body: "ext.one","ext.two",… (each id escaped)
for _ext in $CODE_RECOMMENDED_EXTENSIONS; do
  _e="${_ext//\\/\\\\}"; _e="${_e//\"/\\\"}"; recs="$recs${recs:+,}\"$_e\""
done
incus exec "$INSTANCE_NAME" "${PROJ[@]}" --user "$DEV_UID" --group "$DEV_GID" \
  --env HOME="/home/$DEV_USER" --env WSDIR="${wsfile%/*}" --env WSFILE="$wsfile" \
  --env WSJSON='{"folders":[{"name":"'"$esc_name"'","path":"'"$esc_path"'"}],"extensions":{"recommendations":['"$recs"']}}' -- \
  sh -c 'mkdir -p "$WSDIR" && printf "%s\n" "$WSJSON" > "$WSFILE"' \
  || die "could not write the VS Code workspace file in the yard"
uri="vscode-remote://ssh-remote+$host$wsfile"
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
  info "opening '$name' ($host:$yardPath) in VS Code …"
  exec code --file-uri "$uri"
else
  warn "the 'code' CLI is not on PATH — open it manually:"
  printf '  code --file-uri "%s"\n' "$uri"
  printf '  (or VS Code → Remote-SSH: Connect to Host → %s, then open the %s workspace)\n' "$host" "$name"
fi
