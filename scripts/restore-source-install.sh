#!/usr/bin/env bash
# Restore entrypoints and shell files captured by migrate-source-install.sh.
set -euo pipefail

RECOVERY_ROOT="${SUBYARD_SOURCE_RECOVERY_ROOT:-${SUBYARD_HOME:-$HOME/.subyard}/recovery/pre-go-source}"
while [ $# -gt 0 ]; do
  case "$1" in
    --recovery-root) [ $# -ge 2 ] || exit 2; RECOVERY_ROOT="$2"; shift 2 ;;
    *) printf 'restore-source-install: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
fail() { printf 'restore-source-install: %s\n' "$*" >&2; exit 1; }
case "$RECOVERY_ROOT" in "$HOME"/*) ;; *) fail "recovery root must be inside the operator home" ;; esac
[ -d "$RECOVERY_ROOT" ] && [ ! -L "$RECOVERY_ROOT" ] \
  && [ "$(stat -c '%u' "$RECOVERY_ROOT")" = "$(id -u)" ] \
  || fail "recovery root is missing or not operator-owned"

read_value() {
  [ -f "$RECOVERY_ROOT/$1" ] && [ ! -L "$RECOVERY_ROOT/$1" ] \
    || fail "recovery metadata is incomplete: $1"
  IFS= read -r REPLY < "$RECOVERY_ROOT/$1"
}
read_value bin-dir; bin_dir="$REPLY"
read_value runtime-launcher; runtime_launcher="$REPLY"
read_value yard.target; yard_target="$REPLY"
read_value sy.target; sy_target="$REPLY"
read_value rc.path; rc="$REPLY"
read_value login-rc.path; login_rc="$REPLY"
for path in "$bin_dir" "$runtime_launcher" "$yard_target" "$sy_target" "$rc" "$login_rc"; do
  case "$path" in *$'\n'*|*$'\t'*) fail "invalid recovery path" ;; esac
done
case "$bin_dir" in "$HOME"/*) ;; *) fail "recovered bin directory escapes the operator home" ;; esac
case "$rc" in "$HOME"/*) ;; *) fail "recovered rc escapes the operator home" ;; esac
case "$login_rc" in "$HOME"/*) ;; *) fail "recovered login rc escapes the operator home" ;; esac

[ -L "$bin_dir/yard" ] && [ -L "$bin_dir/sy" ] \
  || fail "current yard and sy entrypoints are not symbolic links"
[ "$(readlink "$bin_dir/yard")" = "$runtime_launcher" ] \
  && [ "$(readlink "$bin_dir/sy")" = "$runtime_launcher" ] \
  || fail "entrypoints changed after migration; refusing automatic recovery"
read_value rc.after.sha256; rc_after="$REPLY"
[ -f "$rc" ] && [ "$(sha256sum "$rc" | cut -d' ' -f1)" = "$rc_after" ] \
  || fail "interactive shell rc changed after migration; refusing automatic recovery"
read_value login-rc.after.sha256; login_after="$REPLY"
[ -f "$login_rc" ] && [ "$(sha256sum "$login_rc" | cut -d' ' -f1)" = "$login_after" ] \
  || fail "login shell rc changed after migration; refusing automatic recovery"

if [ -f "$RECOVERY_ROOT/created.tsv" ]; then
  while IFS=$'\t' read -r digest path; do
    [ -n "$path" ] || continue
    case "$path" in "$HOME"/*) ;; *) fail "created-file record escapes the operator home" ;; esac
    [ -f "$path" ] && [ ! -L "$path" ] \
      && [ "$(sha256sum "$path" | cut -d' ' -f1)" = "$digest" ] \
      || fail "migrated file changed after installation: $path"
  done < "$RECOVERY_ROOT/created.tsv"
fi

restore_shell_file() {
  local label="$1" path state
  read_value "$label.path"; path="$REPLY"
  read_value "$label.state"; state="$REPLY"
  case "$state" in
    present) install -m "$(stat -c '%a' "$RECOVERY_ROOT/$label.before")" \
      "$RECOVERY_ROOT/$label.before" "$path" ;;
    absent) rm -f -- "$path" ;;
    same) ;;
    *) fail "invalid shell recovery state for $label" ;;
  esac
}
restore_shell_file rc
restore_shell_file login-rc
ln -sfn -- "$yard_target" "$bin_dir/yard"
ln -sfn -- "$sy_target" "$bin_dir/sy"
if [ -f "$RECOVERY_ROOT/created.tsv" ]; then
  while IFS=$'\t' read -r _ path; do
    [ -n "$path" ] && rm -f -- "$path"
  done < "$RECOVERY_ROOT/created.tsv"
fi
read_value data-home; data_home="$REPLY"
read_value config-home; config_home="$REPLY"
case "$data_home" in "$HOME"/*) ;; *) fail "recovered data home escapes the operator home" ;; esac
case "$config_home" in "$HOME"/*) ;; *) fail "recovered config home escapes the operator home" ;; esac
find "$data_home/operator-overlay" "$config_home/yards" \
  -depth -type d -empty -delete 2>/dev/null || true

source_root="$(<"$RECOVERY_ROOT/source-root")"
consumed="$RECOVERY_ROOT.restored.$(date -u +%Y%m%dT%H%M%SZ).$$"
mv "$RECOVERY_ROOT" "$consumed"
printf 'restored source-linked yard entrypoints from %s\n' "$source_root"
printf 'consumed recovery record retained at %s\n' "$consumed"
