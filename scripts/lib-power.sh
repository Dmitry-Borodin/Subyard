#!/usr/bin/env bash
# lib-power.sh — pure helpers for persisted yard power intent and host-network safety.
# Source it from host lifecycle scripts or from the installed boot reconciler. It deliberately
# does not source lib.sh or operator config: the root boot service trusts only Incus metadata.

[ -n "${SUBYARD_LIBPOWER_SOURCED:-}" ] && return 0
SUBYARD_LIBPOWER_SOURCED=1

POWER_KEY_MANAGED=user.subyard.managed
POWER_KEY_NAME=user.subyard.name
POWER_KEY_BRIDGE=user.subyard.bridge
POWER_KEY_DESIRED=user.subyard.desired_power
POWER_KEY_INITIALIZED=user.subyard.initialized
POWER_ERROR=
POWER_IMPORTED=0

power_fail() {
  POWER_ERROR="$*"
  return 1
}

power_get() { # <project> <instance> <key>
  incus config get "$2" "$3" --project "$1" 2>/dev/null || true
}

power_set() { # <project> <instance> <key> <value>
  incus config set "$2" "$3" "$4" --project "$1"
}

power_state() { # <project> <instance>
  incus list "$2" --project "$1" -f csv -c s 2>/dev/null
}

power_initial_desired() {
  case "${1:-default}" in ''|default) printf 'running\n' ;; *) printf 'stopped\n' ;; esac
}

power_valid_desired() {
  case "$1" in running|stopped) return 0 ;; *) return 1 ;; esac
}

power_enforce_autostart_false() { # <project> <instance>
  [ "$(power_get "$1" "$2" boot.autostart)" = false ] \
    || power_set "$1" "$2" boot.autostart false
}

# Import an existing, unmarked yard exactly once. Its current RUNNING/STOPPED state wins so rollout
# never silently starts a stopped yard or disables one that was already running. A managed partial
# init is preserved; only stable identity/bridge metadata and boot.autostart are reconciled.
power_import_instance() { # <project> <instance> <yard-name> <bridge>
  local project="$1" instance="$2" yard_name="${3:-default}" bridge="$4"
  local managed desired initialized current
  POWER_IMPORTED=0
  managed="$(power_get "$project" "$instance" "$POWER_KEY_MANAGED")"
  if [ "$managed" = true ]; then
    desired="$(power_get "$project" "$instance" "$POWER_KEY_DESIRED")"
    power_valid_desired "$desired" || {
      power_fail "$project/$instance has invalid $POWER_KEY_DESIRED='$desired'"
      return 1
    }
    initialized="$(power_get "$project" "$instance" "$POWER_KEY_INITIALIZED")"
    case "$initialized" in
      true|false) ;;
      *) power_fail "$project/$instance has invalid $POWER_KEY_INITIALIZED='$initialized'"; return 1 ;;
    esac
    power_enforce_autostart_false "$project" "$instance" || return 1
    power_set "$project" "$instance" "$POWER_KEY_NAME" "$yard_name" || return 1
    power_set "$project" "$instance" "$POWER_KEY_BRIDGE" "$bridge" || return 1
    return 0
  fi
  [ -z "$managed" ] || {
    power_fail "$project/$instance has unsupported $POWER_KEY_MANAGED='$managed'"
    return 1
  }

  current="$(power_state "$project" "$instance")"
  case "$current" in
    RUNNING) desired=running ;;
    STOPPED) desired=stopped ;;
    *) power_fail "cannot import $project/$instance power state: expected RUNNING or STOPPED, got '${current:-unknown}'"; return 1 ;;
  esac

  # initialized=false is the transaction fence. The boot reconciler ignores/fails closed on a
  # half-written record; initialized=true is committed only after every field is durable.
  power_set "$project" "$instance" "$POWER_KEY_INITIALIZED" false || return 1
  power_enforce_autostart_false "$project" "$instance" || return 1
  power_set "$project" "$instance" "$POWER_KEY_MANAGED" true || return 1
  power_set "$project" "$instance" "$POWER_KEY_NAME" "$yard_name" || return 1
  power_set "$project" "$instance" "$POWER_KEY_BRIDGE" "$bridge" || return 1
  power_set "$project" "$instance" "$POWER_KEY_DESIRED" "$desired" || return 1
  power_set "$project" "$instance" "$POWER_KEY_INITIALIZED" true || return 1
  POWER_IMPORTED=1
}

power_metadata_ready() { # <project> <instance> <bridge>
  local project="$1" instance="$2" bridge="$3" desired
  [ "$(power_get "$project" "$instance" "$POWER_KEY_MANAGED")" = true ] || return 1
  [ "$(power_get "$project" "$instance" "$POWER_KEY_INITIALIZED")" = true ] || return 1
  desired="$(power_get "$project" "$instance" "$POWER_KEY_DESIRED")"
  power_valid_desired "$desired" || return 1
  [ "$(power_get "$project" "$instance" "$POWER_KEY_BRIDGE")" = "$bridge" ] || return 1
  [ "$(power_get "$project" "$instance" boot.autostart)" = false ] || return 1
}

power_intentionally_stopped() { # <project> <instance>
  [ "$(power_get "$1" "$2" "$POWER_KEY_MANAGED")" = true ] \
    && [ "$(power_get "$1" "$2" "$POWER_KEY_INITIALIZED")" = true ] \
    && [ "$(power_get "$1" "$2" "$POWER_KEY_DESIRED")" = stopped ] \
    && [ "$(power_state "$1" "$2")" = STOPPED ]
}

# Validate the effective NetworkManager configuration, not merely our drop-in file: a later distro
# file can override unmanaged-devices and recreate the route-hijack incident. No active NM is safe.
power_nm_active() {
  local state
  if ! command -v systemctl >/dev/null 2>&1; then
    power_nm_binary >/dev/null 2>&1 || return 1
    power_fail "cannot inspect NetworkManager service state"
    return 2
  fi
  state="$(systemctl is-active NetworkManager 2>/dev/null)" || true
  case "$state" in
    active | activating | reloading | deactivating) return 0 ;;
    inactive | failed | unknown) return 1 ;;
    *) power_fail "cannot inspect NetworkManager service state"; return 2 ;;
  esac
}

power_nm_binary() {
  local path
  for path in /usr/sbin/NetworkManager /usr/bin/NetworkManager /sbin/NetworkManager; do
    [ -x "$path" ] && { printf '%s\n' "$path"; return 0; }
  done
  return 1
}

power_nm_prepare_reader() {
  local rc
  if power_nm_active; then :; else
    rc=$?; [ "$rc" -eq 1 ] && return 0
    return "$rc"
  fi
  [ "$(id -u)" -ne 0 ] || return 0
  command -v sudo >/dev/null 2>&1 \
    || { power_fail "sudo is required to verify NetworkManager configuration"; return 1; }
  sudo -v \
    || { power_fail "could not authorize NetworkManager configuration check"; return 1; }
}

power_nm_print_config() {
  local binary
  binary="$(power_nm_binary)" || return 1
  if [ "$(id -u)" -eq 0 ]; then
    "$binary" --print-config
  else
    command -v sudo >/dev/null 2>&1 || return 1
    sudo -n -- "$binary" --print-config
  fi
}

power_nm_guard_effective() { # <bridge>
  local bridge="$1" config unmanaged no_auto rc
  if power_nm_active; then :; else
    rc=$?; [ "$rc" -eq 1 ] && return 0
    return "$rc"
  fi
  config="$(power_nm_print_config 2>/dev/null)" || {
    if [ "$(id -u)" -eq 0 ]; then
      power_fail "cannot read NetworkManager's effective configuration"
    else
      power_fail "cannot read NetworkManager's effective configuration as root — run 'sudo -v'"
    fi
    return 1
  }
  unmanaged="$(printf '%s\n' "$config" | sed -n 's/^[[:space:]]*unmanaged-devices[[:space:]]*=[[:space:]]*//p' | tail -n1)"
  no_auto="$(printf '%s\n' "$config" | sed -n 's/^[[:space:]]*no-auto-default[[:space:]]*=[[:space:]]*//p' | tail -n1)"
  case ";$unmanaged;" in *';type:veth;'*) ;; *) power_fail "NM effective unmanaged-devices lacks type:veth"; return 1 ;; esac
  case ";$unmanaged;" in *';driver:veth;'*) ;; *) power_fail "NM effective unmanaged-devices lacks driver:veth"; return 1 ;; esac
  case ";$unmanaged;" in *";interface-name:$bridge;"*) ;; *) power_fail "NM effective unmanaged-devices lacks bridge $bridge"; return 1 ;; esac
  case ";$no_auto;" in *';type:veth;'*) ;; *) power_fail "NM effective no-auto-default lacks type:veth"; return 1 ;; esac
  case ";$no_auto;" in *";interface-name:$bridge;"*) ;; *) power_fail "NM effective no-auto-default lacks bridge $bridge"; return 1 ;; esac
  printf '%s\n' "$config" | grep -Eq '^[[:space:]]*managed[[:space:]]*=[[:space:]]*0([[:space:]]|$)' \
    || { power_fail "NM effective config lacks the managed=0 device guard"; return 1; }
}

power_route_device_unsafe() { # <device> [bridge...]
  local dev="$1" bridge details
  shift
  for bridge in "$@"; do [ "$dev" = "$bridge" ] && return 0; done
  case "$dev" in veth*|tap*|macvtap*|vnet*|docker*|br-*|virbr*) return 0 ;; esac
  details="$(ip -d link show dev "$dev" 2>/dev/null)" || details=
  case " $details " in *' veth '*|*' veth@'*) return 0 ;; esac
  return 1
}

# Fail when any IPv4 default route points through an Incus/container interface. No default route is
# acceptable here: this predicate protects route ownership; it is not an Internet liveness check.
power_routes_safe() { # [bridge...]
  local routes line token expect_dev=0
  command -v ip >/dev/null 2>&1 \
    || { power_fail "ip is required for the host route guard"; return 1; }
  routes="$(ip -4 route show default 2>/dev/null)" \
    || { power_fail "cannot inspect host IPv4 default routes"; return 1; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    expect_dev=0
    for token in $line; do
      if [ "$expect_dev" = 1 ]; then
        if power_route_device_unsafe "$token" "$@"; then
          power_fail "unsafe host default route uses '$token': $line"
          return 1
        fi
        expect_dev=0
      elif [ "$token" = dev ]; then
        expect_dev=1
      fi
    done
  done <<<"$routes"
  return 0
}

power_host_safe() { # <bridge...>
  local bridge
  [ "$#" -gt 0 ] || { power_fail "power_host_safe needs at least one managed bridge"; return 1; }
  for bridge in "$@"; do power_nm_guard_effective "$bridge" || return 1; done
  power_routes_safe "$@"
}

power_start_guarded() { # <project> <instance> <bridge...>
  local project="$1" instance="$2" current err
  shift 2
  power_host_safe "$@" || return 1
  current="$(power_state "$project" "$instance")"
  if [ "$current" != RUNNING ]; then
    incus start "$instance" --project "$project" || {
      power_fail "failed to start $project/$instance"
      return 1
    }
  fi
  if ! power_host_safe "$@"; then
    err="$POWER_ERROR"
    if incus stop "$instance" --project "$project" --force >/dev/null 2>&1; then
      POWER_ERROR="$err; $project/$instance was stopped fail-closed"
    else
      POWER_ERROR="$err; FAILED to stop unsafe $project/$instance"
    fi
    return 1
  fi
}

power_stop_instance() { # <project> <instance>
  local current
  current="$(power_state "$1" "$2")"
  case "$current" in
    RUNNING) incus stop "$2" --project "$1" ;;
    STOPPED) return 0 ;;
    *) power_fail "cannot stop $1/$2 from state '${current:-unknown}'"; return 1 ;;
  esac
}

power_set_desired() { # <project> <instance> <running|stopped>
  power_valid_desired "$3" || { power_fail "invalid desired power '$3'"; return 1; }
  power_enforce_autostart_false "$1" "$2" || return 1
  power_set "$1" "$2" "$POWER_KEY_DESIRED" "$3"
}

power_finalize_instance() { # <project> <instance> <yard-name> <bridge>
  local project="$1" instance="$2" yard_name="${3:-default}" bridge="$4" desired
  power_import_instance "$project" "$instance" "$yard_name" "$bridge" || return 1
  desired="$(power_get "$project" "$instance" "$POWER_KEY_DESIRED")"
  case "$desired" in
    running)
      power_nm_prepare_reader || return 1
      power_start_guarded "$project" "$instance" "$bridge" || return 1
      ;;
    stopped) power_stop_instance "$project" "$instance" || return 1 ;;
    *) power_fail "$project/$instance has invalid desired power '$desired'"; return 1 ;;
  esac
  power_enforce_autostart_false "$project" "$instance" || return 1
  power_set "$project" "$instance" "$POWER_KEY_INITIALIZED" true
}

power_all_instance_rows() {
  incus list --all-projects -f csv -c pns 2>/dev/null
}

power_managed_rows() { # project,name,state; one per managed instance
  local project instance state
  while IFS=, read -r project instance state _; do
    [ -n "$project" ] && [ -n "$instance" ] || continue
    [ "$(power_get "$project" "$instance" "$POWER_KEY_MANAGED")" = true ] || continue
    printf '%s,%s,%s\n' "$project" "$instance" "$state"
  done < <(power_all_instance_rows)
}

power_any_managed_instance() {
  local row
  row="$(power_managed_rows | sed -n '1p')"
  [ -n "$row" ]
}
