#!/usr/bin/env bash
# First-install bootstrap for hosts that do not have a Subyard engine yet.
set -euo pipefail

REPOSITORY="${YARD_RELEASE_REPOSITORY:-Dmitry-Borodin/Subyard}"
CHANNEL=stable
VERSION="${YARD_RELEASE_VERSION:-}"
RUNTIME_ROOT="${YARD_RUNTIME_ROOT:-${SUBYARD_HOME:-$HOME/.subyard}/runtime}"
CACHE_ROOT="${YARD_RELEASE_CACHE:-${SUBYARD_HOME:-$HOME/.subyard}/releases}"
BIN_DIR="${YARD_BIN_DIR:-$HOME/.local/bin}"
OFFLINE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --channel) [ $# -ge 2 ] || { printf 'bootstrap-runtime: --channel needs stable\n' >&2; exit 2; }; CHANNEL="$2"; shift 2 ;;
    --version) [ $# -ge 2 ] || { printf 'bootstrap-runtime: --version needs a value\n' >&2; exit 2; }; VERSION="$2"; shift 2 ;;
    --runtime-root) [ $# -ge 2 ] || { printf 'bootstrap-runtime: --runtime-root needs a path\n' >&2; exit 2; }; RUNTIME_ROOT="$2"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    -y|--yes) shift ;;
    -h|--help)
      printf 'Usage: bootstrap-runtime.sh [--version VERSION] [--offline] [--runtime-root PATH]\n'
      exit 0 ;;
    *) printf 'bootstrap-runtime: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ "$CHANNEL" = stable ] || { printf 'bootstrap-runtime: unsupported channel: %s\n' "$CHANNEL" >&2; exit 2; }
case "$RUNTIME_ROOT" in /*) ;; *) printf 'bootstrap-runtime: runtime root must be absolute\n' >&2; exit 2 ;; esac
[ "$RUNTIME_ROOT" != / ] || { printf 'bootstrap-runtime: refusing filesystem root\n' >&2; exit 2; }

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) os=linux; arch=amd64 ;;
  Linux/aarch64|Linux/arm64) os=linux; arch=arm64 ;;
  *) printf 'bootstrap-runtime: unsupported platform: %s/%s\n' "$(uname -s)" "$(uname -m)" >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { printf 'bootstrap-runtime: jq is required\n' >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { printf 'bootstrap-runtime: sha256sum is required\n' >&2; exit 2; }

tag=""
if [ -z "$VERSION" ]; then
  [ "$OFFLINE" = 0 ] || { printf 'bootstrap-runtime: offline mode requires --version\n' >&2; exit 2; }
  command -v curl >/dev/null 2>&1 || { printf 'bootstrap-runtime: curl is required\n' >&2; exit 2; }
  release_json="$(curl -fsSL --proto '=https' --tlsv1.2 \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/$REPOSITORY/releases/latest")" \
    || { printf 'bootstrap-runtime: could not resolve the stable release\n' >&2; exit 1; }
  tag="$(jq -er '.tag_name | select(type == "string" and length > 0)' <<<"$release_json")" \
    || { printf 'bootstrap-runtime: latest release has no valid tag\n' >&2; exit 1; }
  VERSION="${tag#v}"
else
  tag="${YARD_RELEASE_TAG:-v$VERSION}"
fi
case "$VERSION" in ''|*[!A-Za-z0-9._+-]*) printf 'bootstrap-runtime: unsafe version: %s\n' "$VERSION" >&2; exit 2 ;; esac

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
      *) printf 'bootstrap-runtime: release base URL must use https:// or file://\n' >&2; return 2 ;;
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
    || { printf 'bootstrap-runtime: release download failed; current runtime was not changed\n' >&2; exit 1; }
done

installer="$release_dir/subyard-install-runtime-release.sh"
installer_checksum="$installer.sha256"
for suffix in '' .sha256; do
  fetch "subyard-install-runtime-release.sh$suffix" "$installer$suffix" \
    || { printf 'bootstrap-runtime: installer download failed; current runtime was not changed\n' >&2; exit 1; }
done
read -r installer_expected _ < "$installer_checksum" || true
installer_actual="$(sha256sum "$installer" | cut -d' ' -f1)"
[ "${installer_actual,,}" = "${installer_expected,,}" ] && [ "${#installer_actual}" = 64 ] \
  || { printf 'bootstrap-runtime: installer checksum mismatch\n' >&2; exit 1; }
chmod 0700 "$installer"

printf 'channel=%s available=%s platform=%s/%s\n' "$CHANNEL" "$VERSION" "$os" "$arch"
"$installer" --runtime-root "$RUNTIME_ROOT" \
  --bundle "$bundle" --checksum "$checksum" --manifest "$manifest" --provenance "$provenance"
install -d "$BIN_DIR"
ln -sfn "$RUNTIME_ROOT/current/bin/yard" "$BIN_DIR/yard"
ln -sfn "$RUNTIME_ROOT/current/bin/yard" "$BIN_DIR/sy"
printf 'yard installed: %s/yard\n' "$BIN_DIR"
