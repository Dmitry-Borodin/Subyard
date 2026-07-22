#!/usr/bin/env bash
# Physical VS Code adapter. Go supplies the resolved project snapshot and context.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=scripts/lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"
# shellcheck source=scripts/lib/project-snapshot.sh
. "$SCRIPT_DIR/lib/project-snapshot.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
SSH_HOST="${SSH_HOST:-yard}"
DEV_USER="${DEV_USER:-dev}"
DEV_UID="${DEV_UID:-1000}"
DEV_GID="${DEV_GID:-1000}"
# Space-separated VS Code marketplace IDs.
CODE_RECOMMENDED_EXTENSIONS="${CODE_RECOMMENDED_EXTENSIONS:-anthropic.claude-code openai.chatgpt sst-dev.opencode}"
PROJ=(--project "$INCUS_PROJECT")

project_snapshot_load
host="${SUBYARD_PROJECT_SSH_HOST:-$SSH_HOST}"

if [ -n "$target" ] && [ "$target" != yard ]; then
  box_cname="subyard-box-$id"
  info "'$name' runs in an L2 project-env box (target=$target)."
  cat <<MSG
To edit inside the box (Dev Containers "Attach to Running Container"):
  1) ${PROG:-yard} up $id                   # ensure the box is running
  2) in the VS Code window that opens (connected to the yard over Remote-SSH),
     run "Dev Containers: Attach to Running Container" -> $box_cname  (folder /workspace)
Opening the Remote-SSH entry to the yard now ...
MSG
fi

if [ "${YARD_TYPE:-local}" = remote ]; then
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 "$host" true \
    || die "remote yard is unavailable"
else
  incus_preflight code
  [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
    || die "yard is not running — start it: yard start"
  incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx ssh \
    || die "SSH access not set up — run 'yard init' (or scripts/07-ssh-access.sh)"
fi

if [ "${YARD_TYPE:-local}" = remote ]; then
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

# Give the remote workspace a useful name and extension recommendations.
wsfile="/home/$DEV_USER/.subyard/workspaces/${name//[^A-Za-z0-9._-]/_}.code-workspace"
esc_name="${name//\\/\\\\}";    esc_name="${esc_name//\"/\\\"}"
esc_path="${yardPath//\\/\\\\}"; esc_path="${esc_path//\"/\\\"}"
recs=""   # JSON array body: "ext.one","ext.two",… (each id escaped)
for _ext in $CODE_RECOMMENDED_EXTENSIONS; do
  _e="${_ext//\\/\\\\}"; _e="${_e//\"/\\\"}"; recs="$recs${recs:+,}\"$_e\""
done
wsjson='{"folders":[{"name":"'"$esc_name"'","path":"'"$esc_path"'"}],"extensions":{"recommendations":['"$recs"']}}'
wsdir="${wsfile%/*}"
if [ "${YARD_TYPE:-local}" = remote ]; then
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
  # An empty extension list is inconclusive; only fail on known absence.
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
    if confirm "Install it now (code --install-extension ms-vscode-remote.remote-ssh)?"; then
      code --install-extension ms-vscode-remote.remote-ssh \
        || die "install failed — run it manually: code --install-extension ms-vscode-remote.remote-ssh"
      ok "Remote-SSH installed"
    else
      die "without Remote-SSH, VS Code can't connect to the yard — install it and re-run 'yard code'."
    fi
  fi

  # Reconcile remote extensions only while the VS Code server is idle.
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
    if [ "${YARD_TYPE:-local}" = remote ]; then
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
        unavailable) info "VS Code Server is not installed yet; extension versions will sync on the next 'yard code'" ;;
        busy) warn "remote extension versions differ, but another VS Code window is active; close all remote windows and rerun 'yard code' to synchronize them" ;;
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
