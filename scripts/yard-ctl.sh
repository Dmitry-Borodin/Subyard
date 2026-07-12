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
for a in "$@"; do case "$a" in -y|--yes) ;; -*) die "unknown option '$a'" ;; *) ;; esac; done  # tolerate --yes; reject unknown flags

incus_preflight "$action"
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "instance '$INSTANCE_NAME' missing — run 'yard init' first"

state() { incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null; }

# Yard size on every status, instantly: a cached figure measured from INSIDE the yard.
# There is no fast source (dir pool — Incus tracks no per-instance usage), so a plain
# status prints the cache with its age and, when it is older than SPACE_TTL and the yard
# runs, kicks off one background refresh via incus exec — the container's own root reads
# everything, no host sudo; the next status picks the fresh figure up. The walk covers /
# plus /srv (the yard's own volume) and path-excludes every other mountpoint: `du -x`
# alone is NOT enough, since bind mounts from the same filesystem pass its st_dev check —
# bound host projects would be counted as yard data, and a bind of an in-yard dir would
# be counted twice (du does not dedupe same-fs binds). This is the yard's own data; for
# the full on-host footprint (pool + Incus images + logs, stopped yard included) there is
# no command — it is simply `sudo du -sh ~/.subyard`.
SPACE_CACHE="$SUBYARD_HOME/space.cache"   # "<figure> <epoch>" from the last in-yard du
SPACE_TTL="${SPACE_TTL:-600}"             # cache older than this: refresh in the background

age_human() { # seconds -> 45s / 12m / 3h / 2d
  local s="$1"
  if [ "$s" -lt 60 ]; then echo "${s}s"; elif [ "$s" -lt 3600 ]; then echo "$((s/60))m"
  elif [ "$s" -lt 86400 ]; then echo "$((s/3600))h"; else echo "$((s/86400))d"; fi
}

# One walker at a time (flock -n): a second status during the ~minute-long walk just keeps
# showing the stale figure. The subshell survives this script's exit; write is atomic.
space_refresh_bg() {
  [ -d "$SUBYARD_HOME" ] || return 0
  (
    flock -n 9 || exit 0
    fig="$(incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- sh -c '
      set --
      while read -r _ mp _; do
        case "$mp" in /|/srv) ;; *) set -- "$@" "--exclude=$mp" ;; esac
      done < /proc/mounts
      du -sxh "$@" / 2>/dev/null' | awk '{print $1}' || true)"
    [ -n "$fig" ] || exit 0
    printf '%s %s\n' "$fig" "$(date +%s)" > "$SPACE_CACHE.tmp" && mv -f "$SPACE_CACHE.tmp" "$SPACE_CACHE"
  ) 9>"$SPACE_CACHE.lock" </dev/null >/dev/null 2>&1 &
}

print_space_cached() {
  local running="$1" fig='' ts='' now note=''
  if [ -f "$SPACE_CACHE" ]; then read -r fig ts < "$SPACE_CACHE" || true; fi
  case "$ts" in '' | *[!0-9]*) fig='' ts=0 ;; esac   # tolerate a corrupt/legacy cache
  now="$(date +%s)"
  if [ "$running" = 1 ] && { [ -z "$fig" ] || [ $((now - ts)) -gt "$SPACE_TTL" ]; }; then
    space_refresh_bg
    if [ -n "$fig" ]; then note=', refreshing'; fi
  fi
  if [ -n "$fig" ]; then
    printf '  space    %s  (in-yard rootfs, %s ago%s)\n' "$fig" "$(age_human $((now - ts)))" "$note"
  elif [ "$running" = 1 ]; then
    printf '  space    measuring in the yard — re-run status in a moment\n'
  else
    printf '  space    —  (yard stopped; on-host size: sudo du -sh %s)\n' "$SUBYARD_HOME"
  fi
}


# Shared resources profiles declare (descriptors under config/profiles/*/resources/*.res — the
# registry, via svc_resources_for), one row per resource under a `shared:` heading. Always lists
# what is declared (so the operator sees what *could* run); the live up/down probe needs the yard,
# so pass running=1 to probe (it delegates to the resource's own `is-up`), else every row shows
# '?'. A down resource gets a bring-up hint; an up resource gets a stop hint. Nothing declared
# => one `shared   none`.
#   shared:
#     android   emulator         up     (yard emu stop)
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
        if svc_resource_up "$res"; then
          st=up; hint="$(svc_resource_stop_hint "$res")"
        else
          st=down; hint="$(svc_resource_hint "$res")"
        fi
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
    # Yard size, always, as the last line: instant from the cache, background-refreshed
    # from inside the yard when stale.
    if [ "$s" = RUNNING ]; then print_space_cached 1; else print_space_cached 0; fi
    ;;
  *)
    die "unknown action '$action' (expected: start | stop | status)"
    ;;
esac
