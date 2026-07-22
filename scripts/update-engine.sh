#!/usr/bin/env bash
# Explicit verified runtime update/check/rollback flow for GitHub Releases and an offline cache.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="${YARD_RELEASE_REPOSITORY:-Dmitry-Borodin/Subyard}"
CHANNEL=stable
VERSION="${YARD_RELEASE_VERSION:-}"
RUNTIME_ROOT="${YARD_RUNTIME_ROOT:-${SUBYARD_HOME:-$HOME/.subyard}/runtime}"
CACHE_ROOT="${YARD_RELEASE_CACHE:-${SUBYARD_HOME:-$HOME/.subyard}/releases}"
OFFLINE=0; CHECK_ONLY=0; ROLLBACK=0; FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --channel) [ $# -ge 2 ] || { printf 'update-engine: --channel needs stable\n' >&2; exit 2; }; CHANNEL="$2"; shift 2 ;;
    --version) [ $# -ge 2 ] || { printf 'update-engine: --version needs a value\n' >&2; exit 2; }; VERSION="$2"; shift 2 ;;
    --runtime-root) [ $# -ge 2 ] || { printf 'update-engine: --runtime-root needs a path\n' >&2; exit 2; }; RUNTIME_ROOT="$2"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    --force) FORCE=1; shift ;;
    -y|--yes) shift ;;
    -h|--help)
      printf 'Usage: yard update [--check] [--version VERSION] [--offline] [--rollback] [--force]\n'
      exit 0 ;;
    *) printf 'update-engine: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ "$CHANNEL" = stable ] || { printf 'update-engine: unsupported channel: %s\n' "$CHANNEL" >&2; exit 2; }
case "$RUNTIME_ROOT" in /*) ;; *) printf 'update-engine: runtime root must be absolute\n' >&2; exit 2 ;; esac
[ "$RUNTIME_ROOT" != / ] || { printf 'update-engine: refusing filesystem root\n' >&2; exit 2; }
if [ "$ROLLBACK" = 1 ]; then
  [ "$OFFLINE$CHECK_ONLY$FORCE" = 000 ] && [ -z "$VERSION" ] \
    || { printf 'update-engine: --rollback cannot be combined with update options\n' >&2; exit 2; }
  exec "$SCRIPT_DIR/install-runtime-release.sh" --runtime-root "$RUNTIME_ROOT" --rollback
fi

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) os=linux; arch=amd64 ;;
  Linux/aarch64|Linux/arm64) os=linux; arch=arm64 ;;
  *) printf 'update-engine: unsupported platform: %s/%s\n' "$(uname -s)" "$(uname -m)" >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { printf 'update-engine: jq is required\n' >&2; exit 2; }

tag=""
if [ -z "$VERSION" ]; then
  [ "$OFFLINE" = 0 ] || { printf 'update-engine: offline mode requires --version\n' >&2; exit 2; }
  command -v curl >/dev/null 2>&1 || { printf 'update-engine: curl is required\n' >&2; exit 2; }
  release_json="$(curl -fsSL --proto '=https' --tlsv1.2 \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/$REPOSITORY/releases/latest")" \
    || { printf 'update-engine: could not resolve the stable release\n' >&2; exit 1; }
  tag="$(jq -er '.tag_name | select(type == "string" and length > 0)' <<<"$release_json")" \
    || { printf 'update-engine: latest release has no valid tag\n' >&2; exit 1; }
  VERSION="${tag#v}"
else
  tag="${YARD_RELEASE_TAG:-v$VERSION}"
fi
case "$VERSION" in ''|*[!A-Za-z0-9._+-]*) printf 'update-engine: unsafe version: %s\n' "$VERSION" >&2; exit 2 ;; esac

name="subyard-$VERSION-$os-$arch.tar.gz"
release_dir="$CACHE_ROOT/$VERSION"
bundle="$release_dir/$name"
checksum="$bundle.sha256"
manifest="$bundle.manifest.json"
provenance="$bundle.provenance.json"
install -d -m 0700 "$release_dir"

fetch() { # <name> <destination>
  local asset="$1" destination="$2" temporary
  [ "$OFFLINE" = 0 ] || { [ -f "$destination" ] && [ ! -L "$destination" ]; return; }
  temporary="$(mktemp "$release_dir/.$asset.download.XXXXXX")"
  trap 'rm -f "$temporary"' RETURN
  if [ -n "${YARD_RELEASE_BASE_URL:-}" ]; then
    case "$YARD_RELEASE_BASE_URL" in
      file://*) cp -- "${YARD_RELEASE_BASE_URL#file://}/$asset" "$temporary" ;;
      https://*) curl -fsSL --proto '=https' --tlsv1.2 "$YARD_RELEASE_BASE_URL/$asset" -o "$temporary" ;;
      *) printf 'update-engine: release base URL must use https:// or file://\n' >&2; return 2 ;;
    esac
  else
    curl -fsSL --proto '=https' --tlsv1.2 \
      "https://github.com/$REPOSITORY/releases/download/$tag/$asset" -o "$temporary"
  fi
  chmod 0600 "$temporary"
  mv -f "$temporary" "$destination"
  trap - RETURN
}

for suffix in '' .sha256 .manifest.json .provenance.json; do
  fetch "$name$suffix" "$bundle$suffix" \
    || { printf 'update-engine: release download failed; current runtime was not changed\n' >&2; exit 1; }
done

current=none
current_engine="$RUNTIME_ROOT/current/bin/yard-engine"
if [ -x "$current_engine" ]; then
  current="$(SUBYARD_REPOSITORY_ROOT="$RUNTIME_ROOT/current" "$current_engine" --version 2>/dev/null | awk '{print $2}')"
fi
printf 'channel=%s current=%s available=%s platform=%s/%s\n' "$CHANNEL" "$current" "$VERSION" "$os" "$arch"
[ "$CHECK_ONLY" = 0 ] || exec "$SCRIPT_DIR/install-runtime-release.sh" --check \
  --runtime-root "$RUNTIME_ROOT" --bundle "$bundle" --checksum "$checksum" \
  --manifest "$manifest" --provenance "$provenance"
if [ "$FORCE" = 0 ] && [ "$current" = "$VERSION" ]; then
  printf 'runtime is already current\n'
  exit 0
fi
exec "$SCRIPT_DIR/install-runtime-release.sh" --runtime-root "$RUNTIME_ROOT" \
  --bundle "$bundle" --checksum "$checksum" --manifest "$manifest" --provenance "$provenance"
