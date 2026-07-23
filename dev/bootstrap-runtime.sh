#!/usr/bin/env bash
# Bootstrap a host from release assets.
set -euo pipefail

REPOSITORY="${YARD_RELEASE_REPOSITORY:-Dmitry-Borodin/Subyard}"
CHANNEL=stable
VERSION="${YARD_RELEASE_VERSION:-}"
RUNTIME_ROOT="${YARD_RUNTIME_ROOT:-${SUBYARD_HOME:-$HOME/.subyard}/runtime}"
CACHE_ROOT="${YARD_RELEASE_CACHE:-${SUBYARD_HOME:-$HOME/.subyard}/releases}"
BIN_DIR="${YARD_BIN_DIR:-$HOME/.local/bin}"
OFFLINE=0
ASSUME_YES="${ASSUME_YES:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --channel) [ $# -ge 2 ] || { printf 'bootstrap-runtime: --channel needs stable\n' >&2; exit 2; }; CHANNEL="$2"; shift 2 ;;
    --version) [ $# -ge 2 ] || { printf 'bootstrap-runtime: --version needs a value\n' >&2; exit 2; }; VERSION="$2"; shift 2 ;;
    --runtime-root) [ $# -ge 2 ] || { printf 'bootstrap-runtime: --runtime-root needs a path\n' >&2; exit 2; }; RUNTIME_ROOT="$2"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help)
      printf 'Usage: bootstrap-runtime.sh [--version VERSION] [--offline] [--runtime-root PATH] [--yes]\n'
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
for dependency in jq sha256sum tar gzip; do
  command -v "$dependency" >/dev/null 2>&1 \
    || { printf 'bootstrap-runtime: %s is required\n' "$dependency" >&2; exit 2; }
done
if [ "$OFFLINE" = 0 ]; then
  case "${YARD_RELEASE_BASE_URL:-}" in
    file://*) ;;
    *) command -v curl >/dev/null 2>&1 \
      || { printf 'bootstrap-runtime: curl is required\n' >&2; exit 2; } ;;
  esac
fi

tag=""
if [ -z "$VERSION" ]; then
  [ "$OFFLINE" = 0 ] || { printf 'bootstrap-runtime: offline mode requires --version\n' >&2; exit 2; }
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

# Pick the files that new interactive and login shells actually read. The stable `current` link
# keeps completion valid across upgrades and rollback.
RC="${YARD_SHELL_RC:-}"
if [ -z "$RC" ]; then
  case "${SHELL:-}" in
    *zsh) RC="$HOME/.zshrc" ;;
    *) RC="$HOME/.bashrc" ;;
  esac
fi
LOGIN_RC="${YARD_LOGIN_RC:-}"
if [ -z "$LOGIN_RC" ]; then
  case "${SHELL:-}" in
    *zsh) LOGIN_RC="$HOME/.zprofile" ;;
    *)
      if [ -f "$HOME/.bash_profile" ]; then LOGIN_RC="$HOME/.bash_profile"
      elif [ -f "$HOME/.bash_login" ]; then LOGIN_RC="$HOME/.bash_login"
      else LOGIN_RC="$HOME/.profile"
      fi
      ;;
  esac
fi
case "$RC" in
  *zsh*) completion="$RUNTIME_ROOT/current/completions/yard.zsh" ;;
  *) completion="$RUNTIME_ROOT/current/completions/yard.bash" ;;
esac
need_path_line=1
case ":$PATH:" in *":$BIN_DIR:"*) need_path_line=0 ;; esac

printf 'Install the yard CLI\nThis will:\n'
printf '  - download and verify Subyard %s for %s/%s;\n' "$VERSION" "$os" "$arch"
printf '  - install the immutable runtime under %s;\n' "$RUNTIME_ROOT"
printf '  - link yard and sy under %s;\n' "$BIN_DIR"
printf '  - configure login PATH and shell completion.\n'
if [ "$ASSUME_YES" != 1 ]; then
  if [ ! -t 1 ] || [ ! -r /dev/tty ]; then
    printf 'bootstrap-runtime: confirmation requires a terminal; rerun with --yes for automation\n' >&2
    exit 1
  fi
  printf 'Proceed? [y/N] ' > /dev/tty
  IFS= read -r reply < /dev/tty || reply=''
  case "$reply" in y|Y|yes|YES|Yes) ;; *)
    printf 'bootstrap-runtime: cancelled\n' >&2
    exit 1 ;;
  esac
fi

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

if [ -f "$LOGIN_RC" ] && grep -qF 'Subyard CLI login PATH' "$LOGIN_RC"; then
  :
else
  printf '\n# Subyard CLI login PATH\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$LOGIN_RC"
fi
if [ "$need_path_line" = 1 ]; then
  if [ -f "$RC" ] && grep -qF 'Subyard CLI interactive PATH' "$RC"; then
    :
  else
    printf '\n# Subyard CLI interactive PATH\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$RC"
  fi
fi
if [ -f "$RC" ] && grep -qF 'Subyard CLI completion' "$RC"; then
  :
else
  printf '\n# Subyard CLI completion\n[ -f "%s" ] && source "%s"\n' \
    "$completion" "$completion" >> "$RC"
fi

printf 'yard installed: %s/yard\n' "$BIN_DIR"
if [ "$need_path_line" = 1 ]; then
  printf 'activate it in this shell with: export PATH="%s:$PATH"\n' "$BIN_DIR"
fi
printf 'new shells load yard and completion automatically\n'
