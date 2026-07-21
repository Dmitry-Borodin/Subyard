#!/usr/bin/env bash
# Atomically install a checksum-verified engine artifact or swap back to the previous release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO/bin/yard-engine"
ARTIFACT=''; CHECKSUM=''; ROLLBACK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --artifact) [ $# -ge 2 ] || { printf 'install-engine-release: --artifact needs a path\n' >&2; exit 2; }; ARTIFACT="$2"; shift 2 ;;
    --checksum) [ $# -ge 2 ] || { printf 'install-engine-release: --checksum needs a path\n' >&2; exit 2; }; CHECKSUM="$2"; shift 2 ;;
    --target) [ $# -ge 2 ] || { printf 'install-engine-release: --target needs a path\n' >&2; exit 2; }; TARGET="$2"; shift 2 ;;
    --rollback) ROLLBACK=1; shift ;;
    *) printf 'install-engine-release: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$TARGET" in /*) ;; *) printf 'install-engine-release: target must be absolute\n' >&2; exit 2 ;; esac
[ "$TARGET" != / ] || { printf 'install-engine-release: refusing filesystem root target\n' >&2; exit 2; }
target_dir="$(dirname "$TARGET")"; previous="$TARGET.previous"
install -d "$target_dir"

if [ "$ROLLBACK" = 1 ]; then
  [ -z "$ARTIFACT$CHECKSUM" ] || { printf 'install-engine-release: rollback does not accept artifact options\n' >&2; exit 2; }
  [ -x "$TARGET" ] && [ -x "$previous" ] \
    || { printf 'install-engine-release: current and previous engines are required\n' >&2; exit 1; }
  SUBYARD_REPOSITORY_ROOT="$REPO" "$previous" --version >/dev/null \
    || { printf 'install-engine-release: previous engine self-check failed\n' >&2; exit 1; }
  SUBYARD_REPOSITORY_ROOT="$REPO" "$previous" _migrate check >/dev/null \
    || { printf 'install-engine-release: rollback state compatibility check failed\n' >&2; exit 1; }
  swap="$(mktemp "$target_dir/.yard-rollback.XXXXXX")"; rm -f "$swap"
  mv "$TARGET" "$swap"
  if ! mv "$previous" "$TARGET"; then mv "$swap" "$TARGET"; exit 1; fi
  mv "$swap" "$previous"
  printf 'rolled back engine to %s\n' "$(SUBYARD_REPOSITORY_ROOT="$REPO" "$TARGET" --version)"
  exit 0
fi

[ -n "$ARTIFACT" ] && [ -n "$CHECKSUM" ] \
  || { printf 'install-engine-release: --artifact and --checksum are required\n' >&2; exit 2; }
[ -f "$ARTIFACT" ] && [ ! -L "$ARTIFACT" ] && [ -f "$CHECKSUM" ] && [ ! -L "$CHECKSUM" ] \
  || { printf 'install-engine-release: artifact and checksum must be regular non-symlink files\n' >&2; exit 2; }
read -r expected _ < "$CHECKSUM" || true
[ "${#expected}" -eq 64 ] || { printf 'install-engine-release: invalid SHA-256 file\n' >&2; exit 2; }
case "$expected" in *[!0-9a-fA-F]*) printf 'install-engine-release: invalid SHA-256 value\n' >&2; exit 2 ;; esac
actual="$(sha256sum "$ARTIFACT" | cut -d' ' -f1)"
[ "${actual,,}" = "${expected,,}" ] \
  || { printf 'install-engine-release: checksum mismatch\n' >&2; exit 1; }

candidate="$(mktemp "$target_dir/.yard-engine.candidate.XXXXXX")"
backup=''
trap 'rm -f "$candidate" ${backup:+"$backup"}' EXIT
install -m 0755 "$ARTIFACT" "$candidate"
SUBYARD_REPOSITORY_ROOT="$REPO" "$candidate" --version >/dev/null \
  || { printf 'install-engine-release: candidate self-check failed\n' >&2; exit 1; }
SUBYARD_REPOSITORY_ROOT="$REPO" "$candidate" _migrate apply >/dev/null \
  || { printf 'install-engine-release: state migration failed\n' >&2; exit 1; }
if [ -e "$TARGET" ]; then
  [ -f "$TARGET" ] && [ ! -L "$TARGET" ] \
    || { printf 'install-engine-release: current target is not a regular file\n' >&2; exit 1; }
  backup="$(mktemp "$target_dir/.yard-engine.previous.XXXXXX")"
  install -m 0755 "$TARGET" "$backup"
fi
mv -f "$candidate" "$TARGET"; candidate=''
if [ -n "$backup" ]; then mv -f "$backup" "$previous"; backup=''; fi
trap - EXIT
printf 'installed engine %s\n' "$(SUBYARD_REPOSITORY_ROOT="$REPO" "$TARGET" --version)"
