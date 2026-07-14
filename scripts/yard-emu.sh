#!/usr/bin/env bash
# yard-emu.sh — host-facing bridge to the in-yard Android emulator (P1: one emulator).
#
# The emulator boots headless inside the yard (config/profiles/android/emulator-run.sh)
# and listens on the yard's loopback (adb :5555 for the first AVD). Agents in the yard
# already use that loopback directly; these verbs add a host-side view of the same
# emulator — through the yard, never exposing it on the LAN.
#
# One symmetric pair — the host bridge is managed automatically, never as a separate verb:
#   up [avd] [-- args]  boot the emulator headless in the yard (launcher via cage+Xwayland
#                     HW-GPU, detached) AND bridge it to the host: an Incus proxy device
#                     host 127.0.0.1:$ADB_PROXY_PORT -> yard 127.0.0.1:$ADB_EMULATOR_PORT
#                     (loopback only, never on the LAN). Idempotent; waits for the adb port.
#   down              stop the emulator (disrupts agents using it — confirms first) AND
#                     remove the proxy device(s). The full reverse of `up`.
#   status            show emulator (process / adb port / boot_completed) and bridge state.
#   view [--no-control]  `adb connect` + scrcpy the screen (bridge ensured). Control is ON
#                     by default; --no-control (alias --view-only) = look-but-don't-touch,
#                     for when an agent is driving the emulator. `-- args` go to scrcpy.
#                     Needs host adb+scrcpy.
# (`stop` is accepted as an alias of `down`; the old bridge-only `adb`/`tunnel` verbs are gone.)
#
# Operator-owned; no root. Config: config/ports.env + config/incus.project.env + subyard.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-service.sh
. "$SCRIPT_DIR/lib-service.sh"   # profile shared-resource helpers: yexec, svc_require_yard_running

DEV_USER="${DEV_USER:-dev}"
SSH_HOST="${SSH_HOST:-yard}"
ADB_EMULATOR_PORT="${ADB_EMULATOR_PORT:-5555}"
ADB_PROXY_PORT="${ADB_PROXY_PORT:-15555}"
ADB_CONSOLE_EMULATOR_PORT="${ADB_CONSOLE_EMULATOR_PORT:-5554}"
ADB_CONSOLE_PROXY_PORT="${ADB_CONSOLE_PROXY_PORT:-}"

ADB_DEVICE=adb-emu              # Incus proxy device names (yard config)
ADB_CONSOLE_DEVICE=adb-emu-console

# Where the launcher is staged in the yard, and where its boot log goes. EMU_DIR is
# root-owned (push target); EMU_LOG lives in /tmp so the dev user can write it.
EMU_DIR=/tmp/subyard-android
EMU_LOG=/tmp/subyard-android-emu.log
PROFILE_SRC="$SCRIPT_DIR/../config/profiles/android"

device_exists() { incus config device list "$INSTANCE_NAME" "${PROJ[@]}" 2>/dev/null | grep -qx "$1"; }

# Is something listening on the in-yard adb port? (emulator fully up). Best-effort; needs ss.
emulator_listening() {
  yexec sh -c "command -v ss >/dev/null 2>&1 && ss -Hltn 'sport = :$ADB_EMULATOR_PORT' 2>/dev/null | grep -q ." 2>/dev/null
}

# Is the emulator process tree alive in the yard? Covers the whole boot: the launcher
# (bash, pre-`exec cage`), the cage wrapper, the emulator binary, and the qemu VM it
# spawns. Matching only qemu-system would miss the cage->qemu window and read as "dead".
EMU_PGREP='emulator-run.sh|cage --|/emulator/emulator|qemu-system'
emulator_proc() { yexec pgrep -f "$EMU_PGREP" >/dev/null 2>&1; }

# Yard must be reachable and running before we can touch its devices or reach the emulator.
# Shared across profile resources (lib-service.sh): incus reachable + instance RUNNING.
require_yard_running() { svc_require_yard_running; }

# Best-effort: warn (do not fail) when nothing is listening on the in-yard adb port — the
# proxy is still valid, but `adb connect` will hang until the emulator finishes booting.
warn_if_emulator_down() {
  if yexec sh -c "command -v ss >/dev/null 2>&1" 2>/dev/null && ! emulator_listening; then
    warn "nothing is listening on yard 127.0.0.1:$ADB_EMULATOR_PORT yet — boot it: yard emu up (then wait for boot_completed)."
  fi
}

# Idempotent proxy-device add. $1 device name, $2 host port, $3 yard port, $4 'quiet' to
# skip the announce/confirm (the caller's own announce already covered the bridge).
ensure_proxy() {
  local dev="$1" hport="$2" yport="$3" quiet="${4:-}"
  if device_exists "$dev"; then
    ok "proxy device '$dev' already attached (127.0.0.1:$hport -> yard:$yport)"
    return 0
  fi
  if [ "$quiet" != quiet ]; then
    announce "yard emu: adb bridge" \
      "Add an Incus proxy device '$dev': host 127.0.0.1:$hport -> yard 127.0.0.1:$yport (loopback only)." \
      "The emulator is NOT exposed on the LAN; host traffic reaches it through the yard."
    proceed_or_die y   # transient bring-up (bridge the shared emulator) — default Yes
  fi
  incus config device add "$INSTANCE_NAME" "$dev" proxy "${PROJ[@]}" \
    listen="tcp:127.0.0.1:$hport" connect="tcp:127.0.0.1:$yport" bind=host >/dev/null
  ok "added proxy 127.0.0.1:$hport -> yard:$yport"
}

# The whole host bridge (adb proxy + optional console proxy), used by `up` and `view`.
ensure_bridge() {
  local quiet="${1:-}"
  ensure_proxy "$ADB_DEVICE" "$ADB_PROXY_PORT" "$ADB_EMULATOR_PORT" "$quiet"
  if [ -n "$ADB_CONSOLE_PROXY_PORT" ]; then
    ensure_proxy "$ADB_CONSOLE_DEVICE" "$ADB_CONSOLE_PROXY_PORT" "$ADB_CONSOLE_EMULATOR_PORT" "$quiet"
  fi
}

# scrcpy/adb are host tools — detect→advise (we do not install them onto the host).
need_host_tool() {
  command -v "$1" >/dev/null 2>&1 && return 0
  die "host tool '$1' not found — install it on the host, then re-run (e.g. apt install $1 / brew install $1)."
}

# scrcpy ≥ 2.4 dropped the old SurfaceControl.createDisplay(String,boolean) path that
# modern Android (14+) removed; an older scrcpy dies with NoSuchMethodException on a
# recent AVD. Warn (don't block) — the host's Android may be older. Needs sort -V.
SCRCPY_MIN=2.4
warn_if_old_scrcpy() {
  local ver
  ver="$(scrcpy --version 2>/dev/null | head -n1 | awk '{print $2}')"
  [ -n "$ver" ] || return 0
  if [ "$(printf '%s\n%s\n' "$SCRCPY_MIN" "$ver" | sort -V | head -n1)" != "$SCRCPY_MIN" ]; then
    warn "scrcpy $ver is older than $SCRCPY_MIN — recent AVDs (Android 14+) need a newer scrcpy."
    warn "upgrade it (e.g. 'sudo snap install scrcpy', or a release from github.com/Genymobile/scrcpy),"
    warn "else scrcpy fails with NoSuchMethodException (SurfaceControl.createDisplay / IClipboard)."
  fi
}

cmd_view() {
  # Control ON by default (interactive); --no-control (alias --view-only) for read-only.
  local control=""
  local extra=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --control)               control=""; shift ;;
      --no-control|--view-only) control="--no-control"; shift ;;
      --)                      shift; extra=("$@"); break ;;
      -y|--yes)                shift ;;
      *)                       extra+=("$1"); shift ;;
    esac
  done
  need_host_tool adb
  need_host_tool scrcpy
  warn_if_old_scrcpy
  require_yard_running
  echo "adb bridge:"
  ensure_bridge
  warn_if_emulator_down
  local serial="127.0.0.1:$ADB_PROXY_PORT"
  # Reset first: if the proxy was attached before the emulator booted, adb cached the
  # device as 'offline' and a plain `adb connect` won't clear it. disconnect→connect does.
  info "adb (re)connect $serial"
  adb disconnect "$serial" >/dev/null 2>&1 || true
  adb connect "$serial" >/dev/null || die "adb could not connect to $serial — is the emulator booted? (yard emu status)"
  # Wait for it to come online so scrcpy doesn't race a half-up device.
  local _i state=
  for _i in $(seq 1 15); do
    state="$(adb -s "$serial" get-state 2>/dev/null | tr -d '\r' || true)"
    [ "$state" = device ] && break
    sleep 1
  done
  [ "$state" = device ] || die "device $serial is '$state' — not ready. Check: yard emu status"
  info "scrcpy -s $serial ${control:-(control enabled)}"
  exec scrcpy -s "$serial" ${control:+$control} ${extra[@]+"${extra[@]}"}
}

# Remove the proxy device(s) — the bridge half of `down`.
remove_bridge() {
  local removed=0 dev
  for dev in "$ADB_DEVICE" "$ADB_CONSOLE_DEVICE"; do
    if device_exists "$dev"; then
      incus config device remove "$INSTANCE_NAME" "$dev" "${PROJ[@]}" >/dev/null
      ok "removed proxy device '$dev'"
      removed=1
    fi
  done
  [ "$removed" = 1 ] || ok "no emu proxy device attached — nothing to remove"
}

# --- emulator lifecycle (in the yard) ----------------------------------------------
# Stage the launcher (emulator-run.sh + profile.conf) into the yard. The repo/config is
# not mounted in the yard, so push the two files the launcher needs side by side.
stage_launcher() {
  [ -r "$PROFILE_SRC/emulator-run.sh" ] || die "launcher missing: $PROFILE_SRC/emulator-run.sh"
  [ -r "$PROFILE_SRC/profile.conf" ]    || die "profile.conf missing: $PROFILE_SRC/profile.conf"
  incus file push "$PROFILE_SRC/emulator-run.sh" "$INSTANCE_NAME$EMU_DIR/emulator-run.sh" \
    "${PROJ[@]}" --create-dirs --mode 0755 >/dev/null
  incus file push "$PROFILE_SRC/profile.conf" "$INSTANCE_NAME$EMU_DIR/profile.conf" \
    "${PROJ[@]}" --mode 0644 >/dev/null
}

cmd_up() {
  # Pass an optional AVD name and any `-- extra` straight to the launcher.
  local fwd=()
  while [ $# -gt 0 ]; do
    case "$1" in -y|--yes) shift ;; --) shift; fwd+=("$@"); break ;; *) fwd+=("$1"); shift ;; esac
  done
  require_yard_running
  if emulator_listening; then
    ok "emulator already listening on yard 127.0.0.1:$ADB_EMULATOR_PORT — nothing to boot."
    echo "adb bridge:"
    ensure_bridge
    finish_up
    return 0
  fi
  if emulator_proc; then
    # A boot is already in progress — attach to it (wait), do NOT launch a second emulator.
    info "an emulator is already starting in the yard — waiting for the adb port (not launching another)…"
  else
    announce "yard emu: boot the emulator in the yard ($INSTANCE_NAME)" \
      "Stage the launcher into the yard ($EMU_DIR) and run it as '$DEV_USER', detached." \
      "Headless HW-GPU (cage + Xwayland on the passed-through render node); shared with in-yard agents." \
      "Bridge it to the host: proxy 127.0.0.1:$ADB_PROXY_PORT -> yard:$ADB_EMULATOR_PORT (loopback only)." \
      "Log: $EMU_LOG (in the yard). The full reverse is: yard emu down"
    proceed_or_die y   # transient start (boot the shared emulator) — default Yes
    stage_launcher
    ok "launcher staged at $EMU_DIR (in the yard)"
    # Detached: setsid + redirect + </dev/null so it outlives this incus exec session. A
    # login shell (su -) sources /etc/profile.d/subyard-android.sh for ANDROID_HOME/PATH.
    yexec su - "$DEV_USER" -c \
      "setsid sh -c 'exec bash $EMU_DIR/emulator-run.sh ${fwd[*]:-} >$EMU_LOG 2>&1 </dev/null' & echo started" >/dev/null \
      || die "could not launch the emulator (see $EMU_LOG in the yard: yard shell -- tail -n40 $EMU_LOG)"
    info "emulator launching — waiting for adb 127.0.0.1:$ADB_EMULATOR_PORT in the yard (up to ~180s)…"
  fi

  # Poll for the adb port; bail early only if the whole process tree is gone (real failure).
  local _i
  for _i in $(seq 1 60); do
    if emulator_listening; then
      ok "emulator is up — adb listening on yard 127.0.0.1:$ADB_EMULATOR_PORT"
      echo "adb bridge:"
      ensure_bridge quiet   # covered by the announce above
      finish_up
      return 0
    fi
    if ! emulator_proc; then
      warn "emulator process tree is gone — boot likely failed. Last log lines:"
      yexec sh -c "tail -n 20 $EMU_LOG 2>/dev/null" || true
      die "emulator did not start (full log in the yard: yard shell -- cat $EMU_LOG)"
    fi
    sleep 3
  done
  warn "emulator still not listening after ~180s — it may still be booting. Check: yard emu status"
  warn "log (in the yard): yard shell -- tail -n40 $EMU_LOG"
}

# Shared tail of a successful `up`: the connect line + next steps.
finish_up() {
  cat <<MSG

Connect from the host:
  adb connect 127.0.0.1:$ADB_PROXY_PORT
  yard emu status                  # check boot_completed
  yard emu view                    # scrcpy the screen
Shut it down (emulator + bridge):  yard emu down
MSG
}

cmd_down() {
  require_yard_running
  # Emulator half (confirm — it disrupts in-yard agents), then the bridge half. `down` is
  # the full reverse of `up`: nothing emulator-related stays behind.
  if emulator_listening || emulator_proc; then
    announce "yard emu: shut down the in-yard emulator (and its host bridge)" \
      "Kill the emulator (and its cage wrapper) in the yard '$INSTANCE_NAME'." \
      "This DISRUPTS any in-yard agent currently using the emulator for tests." \
      "Remove the host proxy device(s)."
    proceed_or_die y   # transient stop (shut the shared emulator down) — default Yes
    # Clean shutdown via the console if reachable, then make sure the processes are gone.
    yexec su - "$DEV_USER" -c 'adb -s emulator-'"$ADB_CONSOLE_EMULATOR_PORT"' emu kill 2>/dev/null; true' >/dev/null 2>&1 || true
    yexec sh -c "pkill -f qemu-system 2>/dev/null; pkill -f emulator-run.sh 2>/dev/null; pkill cage 2>/dev/null; true" >/dev/null 2>&1 || true
    ok "emulator stopped"
  else
    ok "no emulator running in the yard"
  fi
  echo "adb bridge:"
  remove_bridge
}

cmd_status() {
  require_yard_running
  echo "Emulator (in the yard):"
  if emulator_listening; then
    ok "adb port: listening on yard 127.0.0.1:$ADB_EMULATOR_PORT"
    local booted
    booted="$(yexec su - "$DEV_USER" -c 'adb shell getprop sys.boot_completed 2>/dev/null' 2>/dev/null | tr -d '\r' || true)"
    case "$booted" in
      1) ok "boot_completed: 1 (ready)" ;;
      *) warn "boot_completed: ${booted:-<no answer>} (still booting)" ;;
    esac
  elif emulator_proc; then
    warn "process is running but adb 127.0.0.1:$ADB_EMULATOR_PORT not up yet — still booting."
  else
    warn "not running. Boot it: yard emu up"
  fi

  echo "Host bridge:"
  if device_exists "$ADB_DEVICE"; then
    ok "proxy 'adb-emu' attached: host 127.0.0.1:$ADB_PROXY_PORT -> yard 127.0.0.1:$ADB_EMULATOR_PORT"
    info "connect: adb connect 127.0.0.1:$ADB_PROXY_PORT   |   view: yard emu view"
  else
    warn "no bridge attached. 'yard emu up' adds it (with the emulator)."
  fi
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
  up)     cmd_up "$@" ;;
  down | stop) cmd_down "$@" ;;   # stop: back-compat alias
  status) cmd_status "$@" ;;
  view)   cmd_view "$@" ;;
  adb | tunnel) die "'yard emu $sub' is gone — the bridge is managed by up/down (boot+bridge: yard emu up; shut down both: yard emu down)" ;;
  is-up)  emulator_listening && exit 0 || exit 1 ;;  # silent registry probe (yard status)
  ''|-h|--help) _yard_help_and_exit ;;
  *) die "unknown 'yard emu' subcommand: '$sub' (try: up | down | status | view)" ;;
esac
