#!/usr/bin/env bash
# project-code.sh — open an in-yard project in VS Code via Remote-SSH into the yard.
# Usage: project-code.sh [path|name|id]   (default '.'; name/id from `yard list`)
# Resolves the project's machine-local state (yardPath + sshHost) and launches
# `code` against vscode-remote://ssh-remote+<host><yardPath>. target=yard => edit in L1;
# target=<profile> => the project runs in an L2 project-env box (Attach in Container,
# brought up with `yard up`). Operator; no root.
# Remote yards (YARD_TYPE=remote): pure ssh — reachability is an ssh probe (never incus) and
# the VS Code workspace file is written over the yard-<name> alias; Remote-SSH reaches the
# yard through the same ProxyJump alias. A project found only in the yard is registered on
# demand from its meta.
# Config: config/incus.project.env + config/subyard.env + config/host.env.
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
# shellcheck source=scripts/state/store.sh
. "$SCRIPT_DIR/state/store.sh"
# shellcheck source=scripts/state/resolver.sh
. "$SCRIPT_DIR/state/resolver.sh"
# shellcheck source=scripts/state/transport.sh
. "$SCRIPT_DIR/state/transport.sh"
# shellcheck source=scripts/state/metadata.sh
. "$SCRIPT_DIR/state/metadata.sh"
state_validate_all || die "project state validation failed"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
SSH_HOST="${SSH_HOST:-yard}"
DEV_USER="${DEV_USER:-dev}"
DEV_UID="${DEV_UID:-1000}"
DEV_GID="${DEV_GID:-1000}"
# Coding agents to recommend when the workspace opens — space-separated marketplace IDs;
# override in config/subyard.env. When a local copy is installed, `yard code` also advances an
# older remote copy to that version before opening an idle yard. Note: "Codex – OpenAI's coding
# agent" ships as openai.chatgpt; opencode is sst-dev.opencode; Claude Code is anthropic.claude-code.
CODE_RECOMMENDED_EXTENSIONS="${CODE_RECOMMENDED_EXTENSIONS:-anthropic.claude-code openai.chatgpt sst-dev.opencode}"
PROJ=(--project "$INCUS_PROJECT")

arg="."
for a in "$@"; do
  case "$a" in -y|--yes) ;; -*) die "unknown option '$a'" ;; *) arg="$a" ;; esac
done

# Accept a path (default '.'), an exact id, or a project NAME. maybe_reconcile registers on
# demand a project that lives only in the yard (explicit context); resolve_project_ctx then
# resolves across yards and re-execs in the owning yard.
maybe_reconcile "$arg"
resolve_project_ctx "$arg"
id="$RESOLVED_ID"
yardPath="$(state_get "$id" yardPath)"
host="$(state_get "$id" sshHost)"; host="${host:-$SSH_HOST}"
name="$(state_get "$id" name)"; name="${name:-$id}"
target="$(state_get "$id" target)"

# target=<profile> => the project runs in an L2 box. VS Code reaches a container inside the
# yard by first connecting to the yard over Remote-SSH and then attaching to the container
# there (this also composes with a future remote yard). We open the Remote-SSH entry to the
# yard below and print the Attach step; the box itself is brought up with `yard up`.
if [ -n "$target" ] && [ "$target" != yard ]; then
  box_cname="subyard-box-$id"
  info "'$name' runs in an L2 project-env box (target=$target)."
  cat <<MSG
To edit inside the box (Dev Containers "Attach to Running Container"):
  1) ${PROG:-yard} up $arg                  # ensure the box is running
  2) in the VS Code window that opens (connected to the yard over Remote-SSH),
     run "Dev Containers: Attach to Running Container" -> $box_cname  (folder /workspace)
Opening the Remote-SSH entry to the yard now ...
MSG
fi

# Yard must be up, and SSH access must be set up (Remote-SSH needs the proxy + key). Remote:
# the ssh alias is the only path — probe it (never incus); the proxy/key live on the owner host.
if yard_is_remote; then
  require_remote_reachable
else
  incus_preflight code
  [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
    || die "yard is not running — start it: yard start"
  incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx ssh \
    || die "SSH access not set up — run 'yard init' (or scripts/07-ssh-access.sh)"
fi

# Opportunistic owner-host key catch-up before opening the real Remote-SSH session. The six-hour
# timer remains authoritative; this bounded hook only reduces staleness during active use.
if yard_is_remote; then
  _key_rc='yard'
  [ -z "${REMOTE_YARD:-}" ] || _key_rc="$_key_rc -Y $(printf '%q' "$REMOTE_YARD")"
  _key_rc="$_key_rc _keys-auto-sync --if-due"
  if command -v timeout >/dev/null 2>&1; then
    timeout "${SUBYARD_KEYS_CONNECT_TIMEOUT:-8}" ssh -o BatchMode=yes -o ConnectTimeout=5 \
      "$REMOTE_DEST" -- bash -lc "$(printf '%q' "$_key_rc")" >/dev/null 2>&1 || true
  else
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_DEST" -- bash -lc "$(printf '%q' "$_key_rc")" >/dev/null 2>&1 || true
  fi
else
  _keys_identity="${SUBYARD_KEYS_ROOT:-$SUBYARD_CONFIG_HOME/keys}/identity.json"
  if [ -r "$_keys_identity" ]; then
    if command -v timeout >/dev/null 2>&1; then
      timeout "${SUBYARD_KEYS_CONNECT_TIMEOUT:-8}" "$SCRIPT_DIR/yard-keys.sh" _auto-worker --if-due >/dev/null 2>&1 || true
    else
      "$SCRIPT_DIR/yard-keys.sh" _auto-worker --if-due >/dev/null 2>&1 || true
    fi
  fi
fi

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
wsjson='{"folders":[{"name":"'"$esc_name"'","path":"'"$esc_path"'"}],"extensions":{"recommendations":['"$recs"']}}'
wsdir="${wsfile%/*}"
if yard_is_remote; then
  # No local incus — write over the alias (logs in as dev). wsdir/wsfile hold only sanitized
  # chars, so single-quoting them for the remote shell is safe; the JSON rides in on stdin.
  printf '%s\n' "$wsjson" | ssh "$host" "mkdir -p '$wsdir' && cat > '$wsfile'" \
    || die "could not write the VS Code workspace file in the yard"
else
  incus exec "$INSTANCE_NAME" "${PROJ[@]}" --user "$DEV_UID" --group "$DEV_GID" \
    --env HOME="/home/$DEV_USER" --env WSDIR="$wsdir" --env WSFILE="$wsfile" \
    --env WSJSON="$wsjson" -- \
    sh -c 'mkdir -p "$WSDIR" && printf "%s\n" "$WSJSON" > "$WSFILE"' \
    || die "could not write the VS Code workspace file in the yard"
fi
uri="vscode-remote://ssh-remote+$host$wsfile"
if command -v code >/dev/null 2>&1; then
  # Remote-SSH must be installed, or `code` gets an ssh-remote:// URI it can't handle and
  # silently no-ops (no SSH connection reaches the yard, no server installs). Block early
  # with the fix. Act only on a KNOWN-missing extension: if we can't enumerate (empty
  # list), proceed rather than false-alarm.
  exts="$(code --list-extensions --show-versions 2>/dev/null || true)"
  local_extension_present() {
    local wanted="${1,,}" line id
    while IFS= read -r line; do
      id="${line%%@*}"
      [ "${id,,}" = "$wanted" ] && return 0
    done <<< "$exts"
    return 1
  }
  local_extension_version() {
    local wanted="${1,,}" line id
    while IFS= read -r line; do
      id="${line%%@*}"
      [ "${id,,}" = "$wanted" ] || continue
      [ "$line" != "$id" ] || return 1
      printf '%s\n' "${line#*@}"
      return 0
    done <<< "$exts"
    return 1
  }
  if [ -n "$exts" ] && ! local_extension_present ms-vscode-remote.remote-ssh; then
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

  # Local and Remote-SSH extension registries are independent. Reconcile the extensions this
  # workspace recommends while no remote window is active, using VS Code Server's own installer;
  # this repairs an update interrupted by a prior container shutdown without deleting settings or
  # extension state from ~/.vscode-server.
  sync_specs=()
  for _ext in $CODE_RECOMMENDED_EXTENSIONS; do
    _version="$(local_extension_version "$_ext" 2>/dev/null || true)"
    case "$_ext@$_version" in
      *@ | *[!A-Za-z0-9._@+-]*) continue ;;
    esac
    sync_specs+=("$_ext@$_version")
  done
  if [ "${#sync_specs[@]}" -gt 0 ]; then
    sync_result=''
    if yard_is_remote; then
      sync_ok=0
      sync_result="$(ssh "$host" sh -s -- sync "${sync_specs[@]}" \
        < "$SCRIPT_DIR/vscode-remote-maintenance.sh" 2>&1)" || sync_ok=$?
    else
      command -v flock >/dev/null 2>&1 || die "flock is required to coordinate VS Code extension maintenance"
      install -d -m 700 "$SUBYARD_HOME"
      exec 8>"$SUBYARD_HOME/vscode${YARD_NAME:+-$YARD_NAME}.lock"
      if ! flock -n 8; then
        info "waiting for yard lifecycle maintenance to finish"
        flock 8 || die "could not acquire the VS Code lifecycle lock"
      fi
      sync_ok=0
      sync_result="$(incus exec "$INSTANCE_NAME" "${PROJ[@]}" \
        --user "$DEV_UID" --group "$DEV_GID" --env HOME="/home/$DEV_USER" -- \
        sh -s -- sync "${sync_specs[@]}" \
        < "$SCRIPT_DIR/vscode-remote-maintenance.sh" 2>&1)" || sync_ok=$?
      flock -u 8
      exec 8>&-
    fi
    sync_status="${sync_result##*$'\n'}"
    if [ "$sync_ok" -ne 0 ]; then
      warn "remote VS Code extension synchronization did not complete; opening with the versions currently installed"
    else
      case "$sync_status" in
        current) ;;
        unavailable) info "VS Code Server is not installed yet; extension versions will sync on the next '$(yard_cmd_hint) code'" ;;
        busy) warn "remote extension versions differ, but another VS Code window is active; close all remote windows and rerun '$(yard_cmd_hint) code' to synchronize them" ;;
        updated:*) ok "remote VS Code extensions matched local versions: ${sync_status#updated:}" ;;
        *) warn "could not confirm remote VS Code extension versions; opening with the versions currently installed" ;;
      esac
    fi
  fi
  info "opening '$name' ($host:$yardPath) in VS Code …"
  exec code --file-uri "$uri"
else
  warn "the 'code' CLI is not on PATH — open it manually:"
  printf '  code --file-uri "%s"\n' "$uri"
  printf '  (or VS Code → Remote-SSH: Connect to Host → %s, then open the %s workspace)\n' "$host" "$name"
fi
