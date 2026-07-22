#!/usr/bin/env bash
# Verify and atomically activate a self-contained Subyard runtime bundle.
set -euo pipefail

RUNTIME_ROOT="${YARD_RUNTIME_ROOT:-${SUBYARD_HOME:-$HOME/.subyard}/runtime}"
BUNDLE=''; CHECKSUM=''; MANIFEST=''; PROVENANCE=''; ROLLBACK=0; CHECK_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) [ $# -ge 2 ] || { printf 'install-runtime-release: --bundle needs a path\n' >&2; exit 2; }; BUNDLE="$2"; shift 2 ;;
    --checksum) [ $# -ge 2 ] || { printf 'install-runtime-release: --checksum needs a path\n' >&2; exit 2; }; CHECKSUM="$2"; shift 2 ;;
    --manifest) [ $# -ge 2 ] || { printf 'install-runtime-release: --manifest needs a path\n' >&2; exit 2; }; MANIFEST="$2"; shift 2 ;;
    --provenance) [ $# -ge 2 ] || { printf 'install-runtime-release: --provenance needs a path\n' >&2; exit 2; }; PROVENANCE="$2"; shift 2 ;;
    --runtime-root) [ $# -ge 2 ] || { printf 'install-runtime-release: --runtime-root needs a path\n' >&2; exit 2; }; RUNTIME_ROOT="$2"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    *) printf 'install-runtime-release: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$RUNTIME_ROOT" in /*) ;; *) printf 'install-runtime-release: runtime root must be absolute\n' >&2; exit 2 ;; esac
[ "$RUNTIME_ROOT" != / ] || { printf 'install-runtime-release: refusing filesystem root\n' >&2; exit 2; }
releases="$RUNTIME_ROOT/releases"; current="$RUNTIME_ROOT/current"; previous="$RUNTIME_ROOT/previous"
install -d -m 0700 "$releases"

safe_link_target() { # <link>
  local value
  [ -L "$1" ] || return 1
  value="$(readlink "$1")"
  case "$value" in releases/*) [ -d "$RUNTIME_ROOT/$value" ] ;; *) return 1 ;; esac
}

activate_link() { # <link> <relative target>
  local link="$1" target="$2" temporary
  temporary="$(mktemp "$RUNTIME_ROOT/.link.XXXXXX")"
  rm -f -- "$temporary"
  ln -s "$target" "$temporary"
  mv -Tf "$temporary" "$link"
}

if [ "$ROLLBACK" = 1 ]; then
  [ "$CHECK_ONLY" = 0 ] \
    || { printf 'install-runtime-release: rollback cannot be combined with check\n' >&2; exit 2; }
  [ -z "$BUNDLE$CHECKSUM$MANIFEST$PROVENANCE" ] \
    || { printf 'install-runtime-release: rollback does not accept release inputs\n' >&2; exit 2; }
  safe_link_target "$current" && safe_link_target "$previous" \
    || { printf 'install-runtime-release: valid current and previous runtimes are required\n' >&2; exit 1; }
  current_target="$(readlink "$current")"; previous_target="$(readlink "$previous")"
  candidate="$RUNTIME_ROOT/$previous_target"
  SUBYARD_REPOSITORY_ROOT="$candidate" "$candidate/bin/yard-engine" --version >/dev/null \
    || { printf 'install-runtime-release: previous runtime self-check failed\n' >&2; exit 1; }
  SUBYARD_REPOSITORY_ROOT="$candidate" "$candidate/bin/yard-engine" _migrate check >/dev/null \
    || { printf 'install-runtime-release: previous runtime state compatibility failed\n' >&2; exit 1; }
  activate_link "$current" "$previous_target"
  activate_link "$previous" "$current_target"
  printf 'rolled back runtime to %s\n' \
    "$(SUBYARD_REPOSITORY_ROOT="$candidate" "$candidate/bin/yard-engine" --version)"
  exit 0
fi

[ -n "$BUNDLE" ] && [ -n "$CHECKSUM" ] && [ -n "$MANIFEST" ] && [ -n "$PROVENANCE" ] \
  || { printf 'install-runtime-release: bundle, checksum, manifest and provenance are required\n' >&2; exit 2; }
for release_file in "$BUNDLE" "$CHECKSUM" "$MANIFEST" "$PROVENANCE"; do
  [ -f "$release_file" ] && [ ! -L "$release_file" ] \
    || { printf 'install-runtime-release: release inputs must be regular non-symlink files\n' >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { printf 'install-runtime-release: jq is required\n' >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { printf 'install-runtime-release: sha256sum is required\n' >&2; exit 2; }

read -r expected _ < "$CHECKSUM" || true
case "$expected" in
  ????????????????????????????????????????????????????????????????) ;;
  *) printf 'install-runtime-release: invalid SHA-256 file\n' >&2; exit 2 ;;
esac
case "$expected" in *[!0-9a-fA-F]*) printf 'install-runtime-release: invalid SHA-256 value\n' >&2; exit 2 ;; esac
actual="$(sha256sum "$BUNDLE" | cut -d' ' -f1)"
[ "${actual,,}" = "${expected,,}" ] \
  || { printf 'install-runtime-release: checksum mismatch\n' >&2; exit 1; }
case "$(uname -m)" in x86_64) host_arch=amd64 ;; aarch64|arm64) host_arch=arm64 ;; *) host_arch=unsupported ;; esac
version="$(jq -er --arg arch "$host_arch" '
  select(.schemaVersion == 1 and .kind == "runtime" and .os == "linux" and .arch == $arch and
    .rpc.min <= 1 and .rpc.max >= 1 and .projectStateSchema == 1 and .credentialSchema == 1) |
  .version | select(type == "string" and length > 0)' "$MANIFEST")" \
  || { printf 'install-runtime-release: incompatible release manifest\n' >&2; exit 1; }
jq -e --arg artifact "$(basename "$BUNDLE")" --arg sha "${actual,,}" --arg version "$version" '
  .schemaVersion == 1 and .artifact == $artifact and (.sha256 | ascii_downcase) == $sha and
  .version == $version and .sourceRepository == "github.com/Dmitry-Borodin/Subyard" and
  (.sourceRevision | type == "string" and length > 0)' "$PROVENANCE" >/dev/null \
  || { printf 'install-runtime-release: provenance does not match the bundle\n' >&2; exit 1; }

if tar -tzf "$BUNDLE" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  printf 'install-runtime-release: bundle contains an unsafe path\n' >&2
  exit 1
fi
if tar -tvzf "$BUNDLE" | awk '
  substr($1, 1, 1) != "-" && substr($1, 1, 1) != "d" { invalid=1 }
  END { exit invalid ? 0 : 1 }
'; then
  printf 'install-runtime-release: bundle contains a non-regular entry\n' >&2
  exit 1
fi
release_id="$version-${actual:0:12}"
destination="$releases/$release_id"
candidate="$(mktemp -d "$releases/.candidate.XXXXXX")"
published=0
cleanup_candidate() { [ "$published" = 1 ] || rm -rf -- "$candidate"; }
trap cleanup_candidate EXIT
tar -xzf "$BUNDLE" -C "$candidate" --no-same-owner --no-same-permissions
if find "$candidate" -type l -print -quit | grep -q .; then
  printf 'install-runtime-release: bundle contains a symbolic link\n' >&2
  exit 1
fi
for required in bin/yard bin/yard-engine config/commands.registry scripts/install-runtime-release.sh; do
  [ -f "$candidate/$required" ] && [ ! -L "$candidate/$required" ] \
    || { printf 'install-runtime-release: bundle is missing %s\n' "$required" >&2; exit 1; }
done
chmod 0755 "$candidate/bin/yard" "$candidate/bin/yard-engine"
candidate_version="$(SUBYARD_REPOSITORY_ROOT="$candidate" "$candidate/bin/yard-engine" --version 2>/dev/null | awk '{print $2}')" \
  || { printf 'install-runtime-release: candidate self-check failed\n' >&2; exit 1; }
[ "$candidate_version" = "$version" ] \
  || { printf 'install-runtime-release: candidate version does not match manifest\n' >&2; exit 1; }
if [ "$CHECK_ONLY" = 1 ]; then
  SUBYARD_REPOSITORY_ROOT="$candidate" "$candidate/bin/yard-engine" _migrate check >/dev/null \
    || { printf 'install-runtime-release: state compatibility check failed\n' >&2; exit 1; }
  printf 'verified runtime yard %s\n' "$version"
  exit 0
fi
SUBYARD_REPOSITORY_ROOT="$candidate" "$candidate/bin/yard-engine" _migrate apply >/dev/null \
  || { printf 'install-runtime-release: state migration failed\n' >&2; exit 1; }

if [ ! -e "$destination" ]; then
  mv "$candidate" "$destination"; published=1
else
  rm -rf -- "$candidate"; published=1
fi
old_target=''
if [ -e "$current" ] || [ -L "$current" ]; then
  safe_link_target "$current" \
    || { printf 'install-runtime-release: current runtime link is unsafe\n' >&2; exit 1; }
  old_target="$(readlink "$current")"
fi
activate_link "$current" "releases/$release_id"
[ -z "$old_target" ] || activate_link "$previous" "$old_target"
trap - EXIT
printf 'installed runtime %s\n' \
  "$(SUBYARD_REPOSITORY_ROOT="$destination" "$destination/bin/yard-engine" --version)"
