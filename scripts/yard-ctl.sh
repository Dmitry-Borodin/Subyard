#!/usr/bin/env bash
# yard-ctl.sh — yard lifecycle: up | down | status.
#   up      start the yard instance (idempotent)
#   down    stop the yard instance (idempotent)
#   status  read-only overview: state, IP, ssh endpoint, mounts, services, projects
# Operator-owned; no root. Config: config/incus.project.env + config/subyard.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

for cfg in incus.project.env subyard.env; do
  f="$SCRIPT_DIR/../config/$cfg"
  # shellcheck disable=SC1090
  [ -r "$f" ] && . "$f"
done
INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
SSH_HOST="${SSH_HOST:-yard}"
SSH_PORT="${SSH_PORT:-2222}"
SUBYARD_CONFIG_HOME="${SUBYARD_CONFIG_HOME:-$HOME/.config/subyard}"
PROJ=(--project "$INCUS_PROJECT")

action="${1:-status}"; shift || true
for a in "$@"; do case "$a" in -y|--yes) ;; *) ;; esac; done  # tolerate --yes

command -v incus >/dev/null 2>&1 || die "incus not found — run 'yard setup' first"
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "instance '$INSTANCE_NAME' missing — run 'yard setup' first"

state() { incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null; }

case "$action" in
  up)
    if [ "$(state)" = RUNNING ]; then
      ok "$INSTANCE_NAME already running"
    else
      info "starting $INSTANCE_NAME"
      incus start "$INSTANCE_NAME" "${PROJ[@]}"
      ok "$INSTANCE_NAME up"
    fi
    ;;
  down)
    cur="$(state)"
    if [ "$cur" = RUNNING ]; then
      info "stopping $INSTANCE_NAME"
      incus stop "$INSTANCE_NAME" "${PROJ[@]}"
      ok "$INSTANCE_NAME down"
    else
      ok "$INSTANCE_NAME already stopped (${cur:-unknown})"
    fi
    ;;
  status)
    s="$(state)"
    printf '%syard%s  %s\n' "$C_HEAD" "$C_OFF" "${s:-unknown}"
    if [ "$s" = RUNNING ]; then
      # eth0 only (the yard also has docker0 172.17.x once Docker is up).
      ip="$(incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- sh -c \
            "ip -4 -o addr show eth0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null)"
      printf '  ip       %s\n' "${ip:-—}"
    fi
    # ssh endpoint (only if the proxy device is attached)
    if incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx ssh; then
      printf '  ssh      127.0.0.1:%s  (ssh %s)\n' "$SSH_PORT" "$SSH_HOST"
    else
      printf '  ssh      not set up  (run: yard setup, or scripts/07-ssh-access.sh)\n'
    fi
    # host mounts attached to the instance
    mounts="$(incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null \
              | grep -E '^host-' | tr '\n' ' ')"
    printf '  mounts   %s\n' "${mounts:-none}"
    # services, only when the yard is up
    if [ "$s" = RUNNING ]; then
      svc="$(incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- systemctl is-active ssh docker 2>/dev/null | tr '\n' '/' )"
      printf '  services ssh/docker = %s\n' "${svc%/}"
    fi
    # project count (machine-local state; no jq dependency here)
    n=0
    if [ -d "$SUBYARD_CONFIG_HOME/projects" ]; then
      for f in "$SUBYARD_CONFIG_HOME/projects"/*.json; do [ -e "$f" ] && n=$((n+1)); done
    fi
    printf '  projects %s  (yard list)\n' "$n"
    ;;
  *)
    die "unknown action '$action' (expected: up | down | status)"
    ;;
esac
