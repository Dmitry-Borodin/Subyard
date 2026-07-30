#!/usr/bin/env bash
# Install the pinned, headless Hermes runtime in one dedicated yard.
set -euo pipefail

die() { printf 'hermes provision: %s\n' "$*" >&2; exit 1; }
if [ "$(id -u)" -ne 0 ] && [ "${HERMES_TEST_ALLOW_NON_ROOT:-0}" != 1 ]; then
  die "must run as root"
fi

profile_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_prefix="${HERMES_TEST_ROOT:-}"
rooted() { printf '%s%s' "$root_prefix" "$1"; }

: "${HERMES_VERSION:?}"
: "${HERMES_TAG:?}"
: "${HERMES_COMMIT:?}"
: "${HERMES_SOURCE_SHA256:?}"
: "${HERMES_PYTHON_VERSION:?}"
: "${HERMES_UV_VERSION:?}"
: "${HERMES_UV_AMD64_SHA256:?}"
: "${HERMES_UV_ARM64_SHA256:?}"
: "${HERMES_HOME:=/srv/hermes}"
: "${HERMES_PORT:=9119}"

DEV_USER="${DEV_USER:-dev}"
DEV_GROUP="${DEV_GROUP:-$(id -gn "$DEV_USER")}"
DEV_HOME="${HERMES_DEV_HOME:-$(getent passwd "$DEV_USER" | cut -d: -f6)}"
DEV_HOME="${DEV_HOME:-/home/$DEV_USER}"

install_root="$(rooted /opt/hermes-agent)"
source_root="$install_root/source"
venv_root="$install_root/venv"
uv_bin="$install_root/bin/uv"
python_root="$install_root/python"
cache_root="$(rooted /var/cache/subyard/hermes-uv)"
state_root="$(rooted "$HERMES_HOME")"
etc_root="$(rooted /etc/subyard)"
runtime_env="$etc_root/hermes-runtime.env"
libexec_root="$(rooted /usr/local/libexec)"
sbin_root="$(rooted /usr/local/sbin)"
unit_root="$(rooted /etc/systemd/system)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl openssl procps

case "$(dpkg --print-architecture)" in
  amd64)
    uv_target=x86_64-unknown-linux-gnu
    uv_sha="$HERMES_UV_AMD64_SHA256"
    ;;
  arm64)
    uv_target=aarch64-unknown-linux-gnu
    uv_sha="$HERMES_UV_ARM64_SHA256"
    ;;
  *) die "unsupported architecture" ;;
esac

download() {
  url="$1"
  output="$2"
  curl --fail --location --silent --show-error \
    --retry 5 --retry-all-errors --connect-timeout 30 "$url" -o "$output"
}

old_commit=""
[ ! -r "$install_root/.subyard-commit" ] || old_commit="$(<"$install_root/.subyard-commit")"
runtime_current=0
if [ "$old_commit" = "$HERMES_COMMIT" ] \
  && [ -r "$install_root/.subyard-source-sha256" ] \
  && [ "$(<"$install_root/.subyard-source-sha256")" = "$HERMES_SOURCE_SHA256" ] \
  && [ -x "$uv_bin" ] && [ -r "$source_root/uv.lock" ]; then
  runtime_current=1
fi

if [ -n "$old_commit" ] && [ "$old_commit" != "$HERMES_COMMIT" ]; then
  verified="$state_root/.last-verified-backup"
  [ -r "$verified" ] && grep -Fxq "commit=$old_commit" "$verified" \
    || die "pin update requires a verified backup of commit $old_commit"
fi
if [ -e "$install_root" ] && [ -z "$old_commit" ]; then
  die "$install_root exists without a Subyard commit marker"
fi

runtime_owner=root
[ "$(id -u)" -eq 0 ] || runtime_owner="$DEV_USER"
previous_runtime=""
if [ "$runtime_current" != 1 ]; then
  previous_runtime="${install_root}.rollback.$$"
  [ ! -e "$previous_runtime" ] || die "stale rollback directory exists"
  if [ -e "$install_root" ]; then
    systemctl stop hermes-serve.service >/dev/null 2>&1 || true
    mv "$install_root" "$previous_runtime"
  fi

  set +e
  (
    set -e
    work="$(mktemp -d)"
    trap 'rm -rf -- "$work"' EXIT
    source_archive="$work/hermes-source.tar.gz"
    uv_archive="$work/uv.tar.gz"

    download \
      "https://codeload.github.com/NousResearch/hermes-agent/tar.gz/$HERMES_COMMIT" \
      "$source_archive"
    printf '%s  %s\n' "$HERMES_SOURCE_SHA256" "$source_archive" | sha256sum -c -
    download \
      "https://github.com/astral-sh/uv/releases/download/$HERMES_UV_VERSION/uv-$uv_target.tar.gz" \
      "$uv_archive"
    printf '%s  %s\n' "$uv_sha" "$uv_archive" | sha256sum -c -

    install -d -m 0755 "$source_root" "$install_root/bin" "$python_root" "$cache_root"
    tar -xzf "$source_archive" -C "$source_root" --strip-components=1 \
      --no-same-owner --no-same-permissions
    tar -xzf "$uv_archive" -C "$work"
    install -m 0755 "$work/uv-$uv_target/uv" "$uv_bin"
    case "$("$uv_bin" --version)" in
      "uv $HERMES_UV_VERSION"|"uv $HERMES_UV_VERSION ($uv_target)") ;;
      *) die "downloaded uv has an unexpected version" ;;
    esac

    (
      cd "$source_root"
      UV_CACHE_DIR="$cache_root" UV_PYTHON_INSTALL_DIR="$python_root" \
        "$uv_bin" python install "$HERMES_PYTHON_VERSION"
      UV_CACHE_DIR="$cache_root" UV_PYTHON_INSTALL_DIR="$python_root" \
        UV_PROJECT_ENVIRONMENT="$venv_root" \
        "$uv_bin" sync --locked --no-dev --python "$HERMES_PYTHON_VERSION"
    )
    [ -x "$venv_root/bin/hermes" ]
    actual_version="$("$venv_root/bin/python" -c \
      'from hermes_cli import __version__; print(__version__)')"
    [ "$actual_version" = "$HERMES_VERSION" ]

    printf '%s\n' "$HERMES_COMMIT" > "$install_root/.subyard-commit"
    printf '%s\n' "$HERMES_SOURCE_SHA256" > "$install_root/.subyard-source-sha256"
    chown -R "$runtime_owner:$runtime_owner" "$install_root" "$cache_root"
    chmod -R go-w "$install_root"
  )
  install_status=$?
  set -e
  if [ "$install_status" -ne 0 ]; then
    rm -rf -- "$install_root"
    if [ -n "$previous_runtime" ] && [ -e "$previous_runtime" ]; then
      mv "$previous_runtime" "$install_root"
    fi
    die "runtime installation failed; previous runtime restored"
  fi
  if [ -n "$previous_runtime" ] && [ -e "$previous_runtime" ]; then
    rm -rf -- "$previous_runtime"
  fi
else
  (
    cd "$source_root"
    UV_CACHE_DIR="$cache_root" UV_PYTHON_INSTALL_DIR="$python_root" \
      UV_PROJECT_ENVIRONMENT="$venv_root" \
      "$uv_bin" sync --locked --no-dev --python "$HERMES_PYTHON_VERSION"
  )
fi

install -d -m 0700 -o "$DEV_USER" -g "$DEV_GROUP" \
  "$state_root" "$state_root/workspace"
serve_env="$state_root/.serve.env"
if [ -e "$serve_env" ]; then
  [ -f "$serve_env" ] && [ ! -L "$serve_env" ] \
    || die "$serve_env must be a regular file"
  token="$(sed -n 's/^HERMES_DASHBOARD_SESSION_TOKEN=//p' "$serve_env")"
  [ "$(wc -l < "$serve_env")" -eq 1 ] || die "invalid session-token file"
  [[ "$token" =~ ^[0-9a-f]{64}$ ]] || die "invalid session token"
else
  token="$(openssl rand -hex 32)"
  tmp_token="$(mktemp "$state_root/.serve.env.XXXXXX")"
  printf 'HERMES_DASHBOARD_SESSION_TOKEN=%s\n' "$token" > "$tmp_token"
  chown "$DEV_USER:$DEV_GROUP" "$tmp_token"
  chmod 0600 "$tmp_token"
  mv "$tmp_token" "$serve_env"
fi
chown "$DEV_USER:$DEV_GROUP" "$serve_env"
chmod 0600 "$serve_env"
unset token

install -d -m 0755 "$etc_root" "$libexec_root" "$sbin_root" "$unit_root"
{
  printf 'HERMES_VERSION=%q\n' "$HERMES_VERSION"
  printf 'HERMES_TAG=%q\n' "$HERMES_TAG"
  printf 'HERMES_COMMIT=%q\n' "$HERMES_COMMIT"
  printf 'HERMES_PORT=%q\n' "$HERMES_PORT"
  printf 'HERMES_HOME=%q\n' "$state_root"
  printf 'HERMES_INSTALL_ROOT=%q\n' "$install_root"
  printf 'HERMES_SOURCE=%q\n' "$source_root"
  printf 'HERMES_VENV=%q\n' "$venv_root"
  printf 'HERMES_DEV_USER=%q\n' "$DEV_USER"
  printf 'HERMES_DEV_GROUP=%q\n' "$DEV_GROUP"
  printf 'HERMES_DEV_HOME=%q\n' "$DEV_HOME"
  printf 'HERMES_PIN_CHECK=%q\n' "$libexec_root/subyard-hermes-pin-check"
  printf 'HERMES_VERIFY_BACKUP=%q\n' "$libexec_root/subyard-hermes-verify-backup"
} > "$runtime_env"
chmod 0644 "$runtime_env"

install -m 0755 "$profile_dir/hermes-pin-check" \
  "$libexec_root/subyard-hermes-pin-check"
install -m 0755 "$profile_dir/verify-backup.py" \
  "$libexec_root/subyard-hermes-verify-backup"
install -m 0755 "$profile_dir/hermes-provider-ready" \
  "$sbin_root/hermes-provider-ready"
install -m 0755 "$profile_dir/hermes-backup-create" \
  "$sbin_root/hermes-backup-create"
install -m 0755 "$profile_dir/hermes-backup-finalize" \
  "$sbin_root/hermes-backup-finalize"
install -m 0755 "$profile_dir/hermes-restore" \
  "$sbin_root/hermes-restore"

unit_tmp="$(mktemp)"
trap 'rm -f -- "$unit_tmp"' EXIT
sed -e "s|@DEV_USER@|$DEV_USER|g" \
  -e "s|@DEV_GROUP@|$DEV_GROUP|g" \
  -e "s|@DEV_HOME@|$DEV_HOME|g" \
  "$profile_dir/hermes-serve.service" > "$unit_tmp"
install -m 0644 "$unit_tmp" "$unit_root/hermes-serve.service"
rm -f -- "$unit_tmp"
trap - EXIT

ready="$state_root/.provider-ready"
if [ -e "$ready" ] && { [ ! -f "$ready" ] || [ "$(<"$ready")" != "$HERMES_COMMIT" ]; }; then
  rm -f -- "$ready"
fi

systemctl daemon-reload
if [ -r "$ready" ] && [ "$(<"$ready")" = "$HERMES_COMMIT" ]; then
  systemctl enable hermes-serve.service >/dev/null
  systemctl try-restart hermes-serve.service >/dev/null 2>&1 || true
else
  systemctl disable --now hermes-serve.service >/dev/null 2>&1 || true
fi

printf 'hermes provision OK: version=%s commit=%s provider_ready=%s\n' \
  "$HERMES_VERSION" "$HERMES_COMMIT" \
  "$([ -r "$ready" ] && printf yes || printf no)"
