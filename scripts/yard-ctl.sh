#!/usr/bin/env bash
# yard-ctl.sh — yard lifecycle: start | stop | status.
#   start   start the yard instance (idempotent)
#   stop    stop the yard instance (idempotent)
#   status  read-only overview: state, IP, ssh endpoint, mounts, services, projects
# Operator-owned; no root. Config: config/incus.project.env + config/subyard.env + config/host.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-service.sh
. "$SCRIPT_DIR/lib-service.sh"   # profile shared-resource helpers: svc_resources_for / svc_resource_up

PROFILES_DIR="$SCRIPT_DIR/../config/profiles"
INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_USER="${DEV_USER:-dev}"
SSH_HOST="${SSH_HOST:-yard}"
SSH_PORT="${SSH_PORT:-2222}"
FORWARD_SSH_AGENT="${FORWARD_SSH_AGENT:-0}"
PROJ=(--project "$INCUS_PROJECT")

action="${1:-status}"; shift || true
SHOW_SPACE=0
for a in "$@"; do case "$a" in --space) SHOW_SPACE=1 ;; -y|--yes) ;; -*) die "unknown option '$a'" ;; *) ;; esac; done  # tolerate --yes; reject unknown flags

incus_preflight "$action"
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "instance '$INSTANCE_NAME' missing — run 'yard init' first"

state() { incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null; }

# Total on-host disk footprint of ~/.subyard (Incus pool + logs/exports/ssh). The pool
# under incus/storage is root-owned (idmapped shift maps it to nobody:nogroup), so a plain
# operator 'du' can't read into it — fall back to sudo for an accurate total when any
# subtree is unreadable, and label a sudo-less figure as partial.
print_space() {
  local base="$SUBYARD_HOME" total note=''
  if [ ! -d "$base" ]; then printf '  space    — (%s absent)\n' "$base"; return; fi
  if find "$base" -mindepth 1 ! -readable -print -quit 2>/dev/null | grep -q .; then
    if command -v sudo >/dev/null 2>&1; then
      total="$(sudo du -sh "$base" 2>/dev/null | awk 'NR==1{print $1}')"
      note=' (root-read)'
    fi
    if [ -z "${total:-}" ]; then
      total="$(du -sh "$base" 2>/dev/null | awk 'NR==1{print $1}')"
      note=' (partial — re-run with sudo for the Incus pool)'
    fi
  else
    total="$(du -sh "$base" 2>/dev/null | awk 'NR==1{print $1}')"
  fi
  printf '  space    %s%s  (%s)\n' "${total:-?}" "$note" "$base"
}

# Shared resources profiles declare (descriptors under config/profiles/*/resources/*.res — the
# registry, via svc_resources_for), one row per resource under a `shared:` heading. Always lists
# what is declared (so the operator sees what *could* run); the live up/down probe needs the yard,
# so pass running=1 to probe (it delegates to the resource's own `is-up`), else every row shows
# '?'. A down resource gets a bring-up hint. Nothing declared => one `shared   none`.
#   shared:
#     android   emulator         up
#     openclaw  staging-gateway  down   (yard staging start)
print_shared() {
  local running="$1" name res st hint any=0
  for d in "$PROFILES_DIR"/*/; do
    [ -r "$d/profile.conf" ] || continue
    name="$(basename "$d")"
    for res in $(svc_resources_for "$name"); do
      [ "$any" = 1 ] || { printf '  shared:\n'; any=1; }
      hint=''
      if [ "$running" = 1 ]; then
        if svc_resource_up "$res"; then st=up; else st=down; hint="$(svc_resource_hint "$res")"; fi
      else
        st='?'
      fi
      if [ -n "$hint" ]; then
        printf '    %-9s %-16s %-5s (%s)\n' "$name" "$res" "$st" "$hint"
      else
        printf '    %-9s %-16s %s\n' "$name" "$res" "$st"
      fi
    done
  done
  [ "$any" = 1 ] || printf '  shared   none\n'
}

case "$action" in
  start | up)  # up: back-compat alias
    if [ "$(state)" = RUNNING ]; then
      ok "$INSTANCE_NAME already running"
    else
      info "starting $INSTANCE_NAME"
      incus start "$INSTANCE_NAME" "${PROJ[@]}"
      ok "$INSTANCE_NAME started"
    fi
    ;;
  stop | down)  # down: back-compat alias
    cur="$(state)"
    if [ "$cur" = RUNNING ]; then
      info "stopping $INSTANCE_NAME"
      incus stop "$INSTANCE_NAME" "${PROJ[@]}"
      ok "$INSTANCE_NAME stopped"
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
      printf '  ssh      not set up  (run: yard init, or scripts/07-ssh-access.sh)\n'
    fi
    # host mounts attached to the instance
    # `|| true`: with no host-* mount, grep exits 1 and pipefail would abort the assignment
    # (killing `yard status` mid-output). An empty result is the correct "none" case here.
    mounts="$(incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null \
              | grep -E '^host-' | tr '\n' ' ' || true)"
    printf '  mounts   %s\n' "${mounts:-none}"
    # services, only when the yard is up
    if [ "$s" = RUNNING ]; then
      svc="$(incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- systemctl is-active ssh docker 2>/dev/null | tr '\n' '/' )"
      printf '  services ssh/docker = %s\n' "${svc%/}"
      # VS Code Remote-SSH access readiness (one glance before `yard code`):
      # key authorized for dev, VS Code server present (installs on first connect),
      # git identity set. agent-forward is a host-side ssh-config option.
      vc="$(incus exec "$INSTANCE_NAME" "${PROJ[@]}" --env DU="$DEV_USER" -- sh -c '
        d="/home/$DU"
        printf "key=%s server=%s git-id=%s" \
          "$([ -s "$d/.ssh/authorized_keys" ] && echo yes || echo no)" \
          "$([ -d "$d/.vscode-server" ] && echo yes || echo not-yet)" \
          "$([ -s "$d/.gitconfig" ] && echo yes || echo no)"' 2>/dev/null)"
      fwd=off; [ "$FORWARD_SSH_AGENT" = 1 ] && fwd=on
      printf '  vscode   %s agent-fwd=%s  (yard code <project>)\n' "${vc:-?}" "$fwd"
    fi
    # project count (machine-local state; no jq dependency here)
    n=0
    if [ -d "$SUBYARD_CONFIG_HOME/projects" ]; then
      for f in "$SUBYARD_CONFIG_HOME/projects"/*.json; do [ -e "$f" ] && n=$((n+1)); done
    fi
    printf '  projects %s  (yard list)\n' "$n"
    # Shared resources profiles expose (emulator / staging gateway). Probe live state only when
    # the yard is up; otherwise just list what is declared (state '?').
    if [ "$s" = RUNNING ]; then print_shared 1; else print_shared 0; fi
    # On-demand disk footprint (du can be slow on a big pool, so opt-in via --space).
    # Must be `if`, not `[ … ] && …`: as the case branch's last command under `set -e`, a bare
    # `&&` returns 1 whenever --space is absent, making a plain `yard status` exit 1 every time.
    if [ "$SHOW_SPACE" = 1 ]; then print_space; fi
    ;;
  *)
    die "unknown action '$action' (expected: start | stop | status)"
    ;;
esac
