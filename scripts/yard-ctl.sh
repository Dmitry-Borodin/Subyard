#!/usr/bin/env bash
# yard-ctl.sh — yard lifecycle: start | stop | status.
#   start   start the yard instance (idempotent)
#   stop    stop the yard instance (idempotent; --force bypasses the VS Code activity guard)
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
all=0
force=0
for a in "$@"; do
  case "$a" in
    --all) all=1 ;;                       # status --all: one status per registered yard
    --force) force=1 ;;                   # stop only: knowingly sever active Remote-SSH sessions
    -y|--yes) ;;
    -*) die "unknown option '$a'" ;;
    *) ;;
  esac
done  # tolerate --yes/--all; reject unknown flags
[ "$force" = 0 ] || case "$action" in stop | down) ;; *) die "--force is only valid with stop" ;; esac

# `status --all`: re-run a plain status for every registry yard, each in a fresh process under
# SUBYARD_YARD=<name> so it loads that yard's own context (each child does its own preflight).
# A REMOTE yard can't run local status (no incus, and the child re-exec bypasses the dispatcher's
# ssh-forward) — so it is summarized from an _info probe / last-seen cache instead (cache format
# matches yard-remote.sh).
remote_status_line() { # <name> <dest> <ryard>
  local name="$1" dest="$2" ryard="$3" rc='yard _info' json state projects cache epoch age=''
  [ -n "$ryard" ] && rc="yard -Y $(printf '%q' "$ryard") _info"
  json="$(ssh -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new \
          "$dest" -- bash -lc "$(printf '%q' "$rc")" 2>/dev/null)" || json=''
  cache="$(remote_cache_path "$name")"
  case "$json" in
    '{'*'}')  # reachable — refresh state and retain last-good projects if live metadata failed
      json="$(remote_info_keep_cached_projects "$json" "$cache")"
      install -d -m 700 "$SUBYARD_HOME" 2>/dev/null || true
      { printf '%s\n' "$(date +%s)"; printf '%s\n' "$json"; } > "$cache.tmp" 2>/dev/null \
        && mv -f "$cache.tmp" "$cache" 2>/dev/null || true ;;
    *)        # unreachable — fall back to the cache
      json=''
      if [ -f "$cache" ]; then
        epoch="$(sed -n 1p "$cache")"; json="$(sed -n 2p "$cache")"
        case "$epoch" in ''|*[!0-9]*) ;; *) age=", seen $(age_human $(( $(date +%s) - epoch ))) ago" ;; esac
      fi ;;
  esac
  if [ -n "$json" ]; then
    state="$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' <<<"$json" | head -n1)"
    projects="$(sed -n 's/.*"projects":\([0-9][0-9]*\).*/\1/p' <<<"$json" | head -n1)"
  else state='?'; projects='?'; fi
  printf '%s%s%s  %s  (remote %s, %s projects%s)\n' \
    "$C_HEAD" "$name" "$C_OFF" "${state:-?}" "$dest" "${projects:-?}" "$age"
}
if [ "$all" = 1 ]; then
  [ "$action" = status ] || die "--all is only valid with status"
  first=1
  while IFS= read -r yn; do
    [ -n "$yn" ] || continue
    [ "$first" = 1 ] || echo; first=0
    if [ "$yn" != default ]; then
      yf="$(yard_env_file "$yn" 2>/dev/null)" || yf=''
      if [ -n "$yf" ] && [ "$(yard_env_val "$yf" YARD_TYPE)" = remote ]; then
        remote_status_line "$yn" "$(yard_env_val "$yf" REMOTE_DEST)" "$(yard_env_val "$yf" REMOTE_YARD)"
        continue
      fi
    fi
    SUBYARD_YARD="$yn" "$SUBYARD_SCRIPT_PATH" status || true
  done < <(yard_registry_names)
  exit 0
fi

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
# Per-yard size cache: the default yard keeps space.cache (byte-identical); a named yard
# gets space-<name>.cache so each yard's figure is independent (and yard-yards.sh reads it).
SPACE_CACHE="$SUBYARD_HOME/space${YARD_NAME:+-$YARD_NAME}.cache"   # "<figure> <epoch>" from the last in-yard du
SPACE_TTL="${SPACE_TTL:-600}"             # cache older than this: refresh in the background

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
#     android   emulator         up     (yard emu down)
#     openclaw  staging-gateway  down   (yard staging start)
print_shared() {
  local running="$1" name res st hint any=0
  local -a active_profiles=()
  # Only the yard's ACTIVE profiles (YARD_PROFILES when set, else all on disk — default yard
  # unchanged), so a named yard lists just its own profiles' shared resources. Materialize the
  # list before probing: resource handlers run `incus exec`, which may consume inherited stdin
  # and would otherwise drain a `while read` profile iterator after the first resource.
  mapfile -t active_profiles < <(yard_profiles_active)
  for name in "${active_profiles[@]}"; do
    [ -n "$name" ] || continue
    [ -r "$PROFILES_DIR/$name/profile.conf" ] || continue
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
  status)
    s="$(state)"
    # Header names the active yard: the default yard prints 'yard' (byte-identical to HEAD);
    # a named yard prints its own name so `status` and `status --all` are unambiguous.
    printf '%s%s%s  %s\n' "$C_HEAD" "${YARD_NAME:-yard}" "$C_OFF" "${s:-unknown}"
    desired="$(power_get "$INCUS_PROJECT" "$INSTANCE_NAME" "$POWER_KEY_DESIRED")"
    initialized="$(power_get "$INCUS_PROJECT" "$INSTANCE_NAME" "$POWER_KEY_INITIALIZED")"
    printf '  desired  %s  (initialized=%s, incus-autostart=%s)\n' \
      "${desired:-unmanaged}" "${initialized:-no}" "$(power_get "$INCUS_PROJECT" "$INSTANCE_NAME" boot.autostart)"
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
      printf '  ssh      not set up  (run: %s init, or scripts/07-ssh-access.sh)\n' "$(yard_cmd_hint)"
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
    # project count (machine-local state; no jq dependency here). Per-yard: reads SUBYARD_STATE_DIR
    # (a named yard's own dir, set by lib.sh's context step; the default yard's projects/).
    n=0
    statedir="${SUBYARD_STATE_DIR:-$SUBYARD_CONFIG_HOME/projects}"
    if [ -d "$statedir" ]; then
      for f in "$statedir"/*.json; do [ -e "$f" ] && n=$((n+1)); done
    fi
    printf '  projects %s  (%s list)\n' "$n" "$(yard_cmd_hint)"
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
