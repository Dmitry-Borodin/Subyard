#!/bin/sh
# vscode-remote-maintenance.sh — run inside a yard to coordinate VS Code Remote-SSH state.
# Usage: sh -s -- check-active | sync <extension@version>...
set -eu

target_identity() {
  if [ -n "${VSCODE_USER:-}" ]; then
    TARGET_UID="$(id -u "$VSCODE_USER" 2>/dev/null)" || return 1
    TARGET_HOME="$(getent passwd "$VSCODE_USER" 2>/dev/null | cut -d: -f6)"
  else
    TARGET_UID="$(id -u)"
    TARGET_HOME="${HOME:-}"
  fi
  [ -n "$TARGET_HOME" ]
}

root_active() { # <server-root>
  root="$1"
  for proc in /proc/[0-9]*; do
    [ -r "$proc/cmdline" ] || continue
    [ "$(stat -c %u "$proc" 2>/dev/null || true)" = "$TARGET_UID" ] || continue
    cmd="$(tr '\000' '\n' 2>/dev/null < "$proc/cmdline" || true)"
    case "$cmd" in
      *"$root/"*)
        case "$cmd" in
          *--type=extensionHost* | *command-shell*) return 0 ;;
        esac
        ;;
    esac
  done
  return 1
}

any_active() {
  root_active "$TARGET_HOME/.vscode-server" \
    || root_active "$TARGET_HOME/.vscode-server-insiders"
}

ssh_session_active() {
  for proc in /proc/[0-9]*; do
    comm="$(tr -d '\n' 2>/dev/null < "$proc/comm" || true)"
    case "$comm" in sshd | sshd-session) return 0 ;; esac
  done
  return 1
}

lock_busy() {
  command -v flock >/dev/null 2>&1 || return 1
  for root in "$TARGET_HOME/.vscode-server" "$TARGET_HOME/.vscode-server-insiders"; do
    lock="$root/.subyard-extension-maintenance.lock"
    [ -f "$lock" ] || continue
    flock -n "$lock" true >/dev/null 2>&1 || return 0
  done
  return 1
}

find_server() {
  SERVER=''
  SERVER_ROOT=''
  for root in "$TARGET_HOME/.vscode-server" "$TARGET_HOME/.vscode-server-insiders"; do
    candidate_server=''
    latest_mtime=0
    for candidate in \
      "$root"/cli/servers/Stable-*/server/bin/code-server \
      "$root"/cli/servers/Insiders-*/server/bin/code-server \
      "$root"/bin/*/bin/code-server; do
      [ -x "$candidate" ] || continue
      case "$candidate" in *.staging/*) continue ;; esac
      mtime="$(stat -c %Y "$candidate" 2>/dev/null || printf '0')"
      if [ -z "$candidate_server" ] || [ "$mtime" -gt "$latest_mtime" ]; then
        candidate_server="$candidate"
        latest_mtime="$mtime"
      fi
    done
    if [ -n "$candidate_server" ]; then
      SERVER="$candidate_server"
      SERVER_ROOT="$root"
      return 0
    fi
  done
  return 1
}

check_active() {
  if ! target_identity; then
    printf 'unknown\n'
  elif lock_busy; then
    printf 'updating\n'
  elif ssh_session_active || any_active; then
    printf 'active\n'
  else
    printf 'idle\n'
  fi
}

sync_extensions() {
  shift
  [ "$#" -gt 0 ] || { printf 'current\n'; return 0; }
  target_identity || { printf 'cannot resolve the VS Code user\n' >&2; return 1; }
  find_server || { printf 'unavailable\n'; return 0; }

  for spec in "$@"; do
    case "$spec" in *@*) ;; *) printf 'invalid extension spec: %s\n' "$spec" >&2; return 2 ;; esac
    id="${spec%@*}"; version="${spec##*@}"
    case "$id" in '' | *[!A-Za-z0-9._-]*) printf 'invalid extension id: %s\n' "$id" >&2; return 2 ;; esac
    case "$version" in '' | *[!A-Za-z0-9._+-]*) printf 'invalid extension version: %s\n' "$version" >&2; return 2 ;; esac
  done

  if command -v flock >/dev/null 2>&1; then
    exec 9>"$SERVER_ROOT/.subyard-extension-maintenance.lock"
    flock -n 9 || { printf 'busy\n'; return 0; }
  fi
  any_active && { printf 'busy\n'; return 0; }

  installed="$("$SERVER" --list-extensions --show-versions)" \
    || { printf 'cannot list remote VS Code extensions\n' >&2; return 1; }
  pending=''
  for spec in "$@"; do
    id="${spec%@*}"; version="${spec##*@}"
    current="$(printf '%s\n' "$installed" | awk -F@ -v wanted="$id" \
      'tolower($1) == tolower(wanted) { print substr($0, length($1) + 2); exit }')"
    if [ -z "$current" ]; then
      pending="$pending $spec"
    elif [ "$current" != "$version" ]; then
      case "$current$version" in *[-+]*) continue ;; esac
      newest="$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -n1)"
      [ "$newest" != "$version" ] || pending="$pending $spec"
    fi
  done
  [ -n "$pending" ] || { printf 'current\n'; return 0; }

  for spec in $pending; do
    "$SERVER" --install-extension "$spec" --force >/dev/null \
      || { printf 'failed to install remote extension %s\n' "$spec" >&2; return 1; }
  done

  installed="$("$SERVER" --list-extensions --show-versions)" \
    || { printf 'cannot verify remote VS Code extensions\n' >&2; return 1; }
  for spec in $pending; do
    id="${spec%@*}"; version="${spec##*@}"
    current="$(printf '%s\n' "$installed" | awk -F@ -v wanted="$id" \
      'tolower($1) == tolower(wanted) { print substr($0, length($1) + 2); exit }')"
    [ "$current" = "$version" ] \
      || { printf 'remote extension did not converge: %s\n' "$spec" >&2; return 1; }
  done
  printf 'updated:%s\n' "${pending# }"
}

case "${1:-}" in
  check-active) check_active ;;
  sync) sync_extensions "$@" ;;
  *) printf 'usage: check-active | sync <extension@version>...\n' >&2; exit 2 ;;
esac
