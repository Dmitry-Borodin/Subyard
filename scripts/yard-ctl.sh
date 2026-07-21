code#!/usr/bin/env bash
# yard-ctl.sh — mutating yard lifecycle safety adapter: start | stop.
#   start   start the yard instance (idempotent)
#   stop    stop the yard instance (idempotent; --force bypasses the VS Code activity guard)
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
# shellcheck source=scripts/lib-power.sh
. "$SCRIPT_DIR/lib-power.sh"
# shellcheck source=scripts/lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"
INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_USER="${DEV_USER:-dev}"
SSH_HOST="${SSH_HOST:-yard}"
PROJ=(--project "$INCUS_PROJECT")

action="${1:-}"; shift || true
force=0
for a in "$@"; do
  case "$a" in
    --force) force=1 ;;                   # stop only: knowingly sever active Remote-SSH sessions
    -y|--yes) ;;
    -*) die "unknown option '$a'" ;;
    *) ;;
  esac
done  # tolerate --yes; reject unknown flags
[ "$force" = 0 ] || case "$action" in stop | down) ;; *) die "--force is only valid with stop" ;; esac

incus_preflight "$action"
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "instance '$INSTANCE_NAME' missing — run '$(yard_cmd_hint) init' first"

state() { incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null; }
BRIDGE="${INCUS_BRIDGE:-${INCUS_NETWORK:-incusbr0}}"
YARD_LABEL="${YARD_NAME:-default}"

prepare_power_marker() {
  power_import_instance "$INCUS_PROJECT" "$INSTANCE_NAME" "$YARD_LABEL" "$BRIDGE" \
    || die "$POWER_ERROR"
  [ "$POWER_IMPORTED" = 0 ] || ok "imported existing power state before lifecycle change"
}

# A container stop cannot gracefully close desktop windows or SSH shells. Refuse to cross an active
# session or an extension write; otherwise an interrupted update can leave extensions.json on the
# old version and every connected window with broken IPC. The in-yard helper also recognizes the
# standalone extension-sync lock used by `yard code`.
vscode_remote_state() {
  local result
  if result="$(incus exec "$INSTANCE_NAME" "${PROJ[@]}" --env VSCODE_USER="$DEV_USER" -- \
      sh -s -- check-active < "$SCRIPT_DIR/vscode-remote-maintenance.sh" 2>/dev/null)"; then
    result="${result##*$'\n'}"
    case "$result" in idle | active | updating | unknown) printf '%s\n' "$result" ;; *) printf 'unknown\n' ;; esac
  else
    printf 'unknown\n'
  fi
}

VSCODE_LIFECYCLE_LOCK="$SUBYARD_HOME/vscode${YARD_NAME:+-$YARD_NAME}.lock"
SSH_SERVICE_WAS_ACTIVE=0
SSH_SOCKET_WAS_ACTIVE=0
SSH_RESTORE_NEEDED=0

vscode_lock_for_stop() {
  command -v flock >/dev/null 2>&1 || die "flock is required for a safe VS Code-aware stop"
  install -d -m 700 "$SUBYARD_HOME"
  exec 8>"$VSCODE_LIFECYCLE_LOCK"
  if ! flock -n 8; then
    info "waiting for remote VS Code extension maintenance to finish"
    flock 8 || die "could not acquire the VS Code lifecycle lock"
  fi
}

# Stop only the SSH listener, never established sessions. With Debian's KillMode=process the
# per-session sshd children survive, so the activity probe can see them while no new Remote-SSH
# window can enter between the probe and `incus stop`.
ssh_listener_quiesce() {
  local result rest
  if ! result="$(incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- sh -eu -c '
    service=0; socket=0
    if systemctl is-active --quiet ssh; then service=1; fi
    if systemctl is-active --quiet ssh.socket; then socket=1; fi
    if [ "$service" = 1 ] && [ "$(systemctl show ssh --property=KillMode --value)" != process ]; then
      printf "unsupported\n"
      exit 0
    fi
    printf "snapshot:%s:%s\n" "$service" "$socket"
  ' 2>/dev/null)"; then
    return 1
  fi
  case "$result" in
    snapshot:[01]:[01])
      rest="${result#snapshot:}"
      SSH_SERVICE_WAS_ACTIVE="${rest%%:*}"
      SSH_SOCKET_WAS_ACTIVE="${rest##*:}"
      SSH_RESTORE_NEEDED=1
      ;;
    unsupported) return 2 ;;
    *) return 1 ;;
  esac
  if ! incus exec "$INSTANCE_NAME" "${PROJ[@]}" \
      --env SERVICE="$SSH_SERVICE_WAS_ACTIVE" --env SOCKET="$SSH_SOCKET_WAS_ACTIVE" -- \
      sh -eu -c '
        [ "$SOCKET" = 0 ] || systemctl stop ssh.socket
        [ "$SERVICE" = 0 ] || systemctl stop ssh
      ' >/dev/null 2>&1; then
    ssh_listener_restore
    return 1
  fi
  return 0
}

ssh_listener_restore() {
  if [ "$SSH_SERVICE_WAS_ACTIVE" = 0 ] && [ "$SSH_SOCKET_WAS_ACTIVE" = 0 ]; then
    SSH_RESTORE_NEEDED=0
    return 0
  fi
  if ! incus exec "$INSTANCE_NAME" "${PROJ[@]}" \
      --env SERVICE="$SSH_SERVICE_WAS_ACTIVE" --env SOCKET="$SSH_SOCKET_WAS_ACTIVE" -- \
      sh -eu -c '
        [ "$SOCKET" = 0 ] || systemctl start ssh.socket
        [ "$SERVICE" = 0 ] || systemctl start ssh
      ' >/dev/null 2>&1; then
    warn "could not restore the yard SSH listener after cancelling stop"
    return 0
  fi
  SSH_SERVICE_WAS_ACTIVE=0
  SSH_SOCKET_WAS_ACTIVE=0
  SSH_RESTORE_NEEDED=0
}

restore_ssh_listener_on_exit() {
  [ "$SSH_RESTORE_NEEDED" = 0 ] || ssh_listener_restore
}
trap restore_ssh_listener_on_exit EXIT

case "$action" in
  start | up)  # up: back-compat alias
    power_nm_prepare_reader || die "$POWER_ERROR"
    prepare_power_marker
    [ "$(state)" = RUNNING ] && info "$INSTANCE_NAME already running; validating host route" \
      || info "starting $INSTANCE_NAME"
    power_start_guarded "$INCUS_PROJECT" "$INSTANCE_NAME" "$BRIDGE" || die "$POWER_ERROR"
    # Commit intent only after both the physical start and post-start host-route check succeeded.
    power_set_desired "$INCUS_PROJECT" "$INSTANCE_NAME" running \
      || die "yard started, but desired-power metadata could not be committed"
    ok "$INSTANCE_NAME started (desired=running; restored after host reboot)"
    ;;
  stop | down)  # down: back-compat alias
    prepare_power_marker
    cur="$(state)"
    if [ "$cur" = RUNNING ]; then
      if [ "$force" = 0 ]; then
        vscode_lock_for_stop
        quiesce_rc=0
        ssh_listener_quiesce || quiesce_rc=$?
        case "$quiesce_rc" in
          0) ;;
          2) die "cannot safely pause new SSH connections: ssh.service KillMode is not 'process'; use '$(yard_cmd_hint) stop --force' only for emergency shutdown" ;;
          *) die "could not pause new SSH connections before checking VS Code; retry, or use '$(yard_cmd_hint) stop --force' for emergency shutdown" ;;
        esac
        vcstate="$(vscode_remote_state)"
        case "$vcstate" in
          active)
            ssh_listener_restore
            die "VS Code Remote-SSH or another SSH session is still connected to '$SSH_HOST' — close every remote window (File > Close Remote Connection) and shell, then retry; use '$(yard_cmd_hint) stop --force' only for emergency shutdown"
            ;;
          updating)
            ssh_listener_restore
            die "a remote VS Code extension update is still writing — wait and retry; use '$(yard_cmd_hint) stop --force' only for emergency shutdown"
            ;;
          unknown)
            ssh_listener_restore
            die "could not verify that VS Code Remote-SSH is idle — retry, or use '$(yard_cmd_hint) stop --force' for emergency shutdown"
            ;;
        esac
      else
        warn "--force bypasses the active SSH / VS Code update guard"
      fi
      info "stopping $INSTANCE_NAME"
      if ! power_stop_instance "$INCUS_PROJECT" "$INSTANCE_NAME"; then
        ssh_listener_restore
        die "could not stop $INSTANCE_NAME"
      fi
      SSH_RESTORE_NEEDED=0
    else
      info "$INSTANCE_NAME already stopped (${cur:-unknown})"
    fi
    # Commit intent only after the stop succeeded (or the instance was already stopped).
    power_set_desired "$INCUS_PROJECT" "$INSTANCE_NAME" stopped \
      || die "yard stopped, but desired-power metadata could not be committed"
    ok "$INSTANCE_NAME stopped (desired=stopped; remains off after host reboot)"
    ;;
  *)
    die "unknown action '$action' (expected: start | stop)"
    ;;
esac
