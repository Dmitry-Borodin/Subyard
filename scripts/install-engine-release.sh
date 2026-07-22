#!/usr/bin/env bash
# Atomically install a checksum-verified engine artifact or swap back to the previous release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${YARD_ENGINE_TARGET:-${SUBYARD_HOME:-$HOME/.subyard}/runtime/yard-engine}"
ARTIFACT=''; CHECKSUM=''; MANIFEST=''; PROVENANCE=''; ROLLBACK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --artifact) [ $# -ge 2 ] || { printf 'install-engine-release: --artifact needs a path\n' >&2; exit 2; }; ARTIFACT="$2"; shift 2 ;;
    --checksum) [ $# -ge 2 ] || { printf 'install-engine-release: --checksum needs a path\n' >&2; exit 2; }; CHECKSUM="$2"; shift 2 ;;
    --manifest) [ $# -ge 2 ] || { printf 'install-engine-release: --manifest needs a path\n' >&2; exit 2; }; MANIFEST="$2"; shift 2 ;;
    --provenance) [ $# -ge 2 ] || { printf 'install-engine-release: --provenance needs a path\n' >&2; exit 2; }; PROVENANCE="$2"; shift 2 ;;
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
  [ -z "$ARTIFACT$CHECKSUM$MANIFEST$PROVENANCE" ] || { printf 'install-engine-release: rollback does not accept artifact options\n' >&2; exit 2; }
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

[ -n "$ARTIFACT" ] && [ -n "$CHECKSUM" ] && [ -n "$MANIFEST" ] && [ -n "$PROVENANCE" ] \
  || { printf 'install-engine-release: artifact, checksum, manifest and provenance are required\n' >&2; exit 2; }
for release_file in "$ARTIFACT" "$CHECKSUM" "$MANIFEST" "$PROVENANCE"; do
  [ -f "$release_file" ] && [ ! -L "$release_file" ] \
    || { printf 'install-engine-release: release inputs must be regular non-symlink files\n' >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { printf 'install-engine-release: jq is required\n' >&2; exit 2; }
read -r expected _ < "$CHECKSUM" || true
[ "${#expected}" -eq 64 ] || { printf 'install-engine-release: invalid SHA-256 file\n' >&2; exit 2; }
case "$expected" in *[!0-9a-fA-F]*) printf 'install-engine-release: invalid SHA-256 value\n' >&2; exit 2 ;; esac
actual="$(sha256sum "$ARTIFACT" | cut -d' ' -f1)"
[ "${actual,,}" = "${expected,,}" ] \
  || { printf 'install-engine-release: checksum mismatch\n' >&2; exit 1; }
case "$(uname -m)" in x86_64) host_arch=amd64 ;; aarch64|arm64) host_arch=arm64 ;; *) host_arch=unsupported ;; esac
version="$(jq -er --arg arch "$host_arch" '
  select(.schemaVersion == 1 and .os == "linux" and .arch == $arch and
    .rpc.min <= 1 and .rpc.max >= 1 and .projectStateSchema == 1 and .credentialSchema == 1) |
  .version | select(type == "string" and length > 0)' "$MANIFEST")" \
  || { printf 'install-engine-release: incompatible release manifest\n' >&2; exit 1; }
jq -e --arg artifact "$(basename "$ARTIFACT")" --arg sha "${actual,,}" --arg version "$version" '
  .schemaVersion == 1 and .artifact == $artifact and (.sha256 | ascii_downcase) == $sha and
  .version == $version and .sourceRepository == "github.com/Dmitry-Borodin/Subyard" and
  (.sourceRevision | type == "string" and length > 0)' "$PROVENANCE" >/dev/null \
  || { printf 'install-engine-release: provenance does not match the artifact\n' >&2; exit 1; }

candidate="$(mktemp "$target_dir/.yard-engine.candidate.XXXXXX")"
backup=''
trap 'rm -f "$candidate" ${backup:+"$backup"}' EXIT
install -m 0755 "$ARTIFACT" "$candidate"
candidate_version="$(SUBYARD_REPOSITORY_ROOT="$REPO" "$candidate" --version 2>/dev/null | awk '{print $2}')" \
  || { printf 'install-engine-release: candidate self-check failed\n' >&2; exit 1; }
[ "$candidate_version" = "$version" ] \
  || { printf 'install-engine-release: candidate version does not match manifest\n' >&2; exit 1; }
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
