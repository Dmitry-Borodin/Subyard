#!/usr/bin/env bash
# Hermes profile checks with fake downloads, uv and systemd.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_DIR="$ROOT/config/profiles/hermes"
PROFILE="$PROFILE_DIR/profile.conf"
HOOK="$PROFILE_DIR/provision.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -x "$HOOK" ] || fail "Hermes provision hook is not executable"
# shellcheck source=config/profiles/hermes/profile.conf
. "$PROFILE"
[ "$PROFILE_NAME" = hermes ] || fail "profile name drifted"
[ "$HERMES_VERSION" = 0.19.0 ] || fail "Hermes version is not pinned"
[[ "$HERMES_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "Hermes commit is not a full SHA"
[[ "$HERMES_SOURCE_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "source hash is invalid"
[ "$HERMES_HOME" = /srv/hermes ] || fail "persistent home drifted"
[ "$HERMES_PORT" = 9119 ] || fail "loopback port drifted"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/source/hermes-fixture" \
  "$tmp/uv/uv-x86_64-unknown-linux-gnu" \
  "$tmp/uv/uv-aarch64-unknown-linux-gnu" "$tmp/root"
printf 'fixture lock\n' > "$tmp/source/hermes-fixture/uv.lock"
printf '[project]\nname="fixture"\n' > "$tmp/source/hermes-fixture/pyproject.toml"
tar -czf "$tmp/source.tar.gz" -C "$tmp/source" hermes-fixture

cat > "$tmp/uv/uv-x86_64-unknown-linux-gnu/uv" <<'UV'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERMES_TEST_UV_LOG"
if [ "${1:-}" = --version ]; then
  printf 'uv %s (x86_64-unknown-linux-gnu)\n' "$HERMES_UV_VERSION"
  exit
fi
if [ "${1:-}" = python ] && [ "${2:-}" = install ]; then
  exit
fi
if [ "${1:-}" = sync ]; then
  mkdir -p "$UV_PROJECT_ENVIRONMENT/bin"
  cat > "$UV_PROJECT_ENVIRONMENT/bin/hermes" <<'HERMES'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'hermes 0.19.0\n'
  exit
fi
exit 90
HERMES
  cat > "$UV_PROJECT_ENVIRONMENT/bin/python" <<'PYTHON'
#!/usr/bin/env bash
if [ "${1:-}" = -c ]; then
  printf '0.19.0\n'
  exit
fi
exec python3 "$@"
PYTHON
  chmod +x "$UV_PROJECT_ENVIRONMENT/bin/hermes" "$UV_PROJECT_ENVIRONMENT/bin/python"
  exit
fi
exit 91
UV
cp "$tmp/uv/uv-x86_64-unknown-linux-gnu/uv" \
  "$tmp/uv/uv-aarch64-unknown-linux-gnu/uv"
chmod +x "$tmp/uv/uv-x86_64-unknown-linux-gnu/uv" \
  "$tmp/uv/uv-aarch64-unknown-linux-gnu/uv"
tar -czf "$tmp/uv.tar.gz" -C "$tmp/uv" \
  uv-x86_64-unknown-linux-gnu uv-aarch64-unknown-linux-gnu
source_sha="$(sha256sum "$tmp/source.tar.gz" | awk '{print $1}')"
uv_sha="$(sha256sum "$tmp/uv.tar.gz" | awk '{print $1}')"

cat > "$tmp/bin/apt-get" <<'APT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERMES_TEST_APT_LOG"
APT
cat > "$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
url=""
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    http*) url="$1"; shift ;;
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$url" ] && [ -n "$output" ]
case "$url" in
  *codeload.github.com*) cp "$HERMES_TEST_SOURCE_ARCHIVE" "$output" ;;
  *astral-sh/uv*) cp "$HERMES_TEST_UV_ARCHIVE" "$output" ;;
  *) exit 92 ;;
esac
printf '%s\n' "$url" >> "$HERMES_TEST_CURL_LOG"
CURL
cat > "$tmp/bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERMES_TEST_SYSTEMCTL_LOG"
SYSTEMCTL
chmod +x "$tmp/bin/apt-get" "$tmp/bin/curl" "$tmp/bin/systemctl"

common_env=(
  PATH="$tmp/bin:$PATH"
  HERMES_TEST_ALLOW_NON_ROOT=1
  HERMES_TEST_ROOT="$tmp/root"
  HERMES_TEST_SOURCE_ARCHIVE="$tmp/source.tar.gz"
  HERMES_TEST_UV_ARCHIVE="$tmp/uv.tar.gz"
  HERMES_TEST_APT_LOG="$tmp/apt.log"
  HERMES_TEST_CURL_LOG="$tmp/curl.log"
  HERMES_TEST_SYSTEMCTL_LOG="$tmp/systemctl.log"
  HERMES_TEST_UV_LOG="$tmp/uv.log"
  DEV_USER="$(id -un)"
  DEV_GROUP="$(id -gn)"
  HERMES_DEV_HOME="$tmp/home"
  HERMES_VERSION="$HERMES_VERSION"
  HERMES_TAG="$HERMES_TAG"
  HERMES_COMMIT="$HERMES_COMMIT"
  HERMES_SOURCE_SHA256="$source_sha"
  HERMES_PYTHON_VERSION="$HERMES_PYTHON_VERSION"
  HERMES_UV_VERSION="$HERMES_UV_VERSION"
  HERMES_UV_AMD64_SHA256="$uv_sha"
  HERMES_UV_ARM64_SHA256="$uv_sha"
  HERMES_HOME="$HERMES_HOME"
  HERMES_PORT="$HERMES_PORT"
)

env "${common_env[@]}" bash "$HOOK" >/dev/null
install_root="$tmp/root/opt/hermes-agent"
state_root="$tmp/root/srv/hermes"
[ "$(<"$install_root/.subyard-commit")" = "$HERMES_COMMIT" ] \
  || fail "runtime commit marker drifted"
[ -x "$install_root/venv/bin/hermes" ] || fail "runtime entrypoint was not installed"
[ -x "$tmp/root/usr/local/sbin/hermes-provider-ready" ] \
  || fail "provider-ready helper was not installed"
[ -x "$tmp/root/usr/local/sbin/hermes-backup-create" ] \
  || fail "backup helper was not installed"
[ -x "$tmp/root/usr/local/sbin/hermes-restore" ] \
  || fail "restore helper was not installed"
[ -f "$tmp/root/etc/systemd/system/hermes-serve.service" ] \
  || fail "systemd unit was not installed"
grep -Fq 'HERMES_DISABLE_LAZY_INSTALLS=1' \
  "$tmp/root/etc/systemd/system/hermes-serve.service" \
  || fail "service does not seal runtime dependencies"
grep -Fq 'ExecStart=/opt/hermes-agent/venv/bin/hermes serve --host 127.0.0.1 --port 9119 --skip-build' \
  "$tmp/root/etc/systemd/system/hermes-serve.service" \
  || fail "service bind or command drifted"
[ "$(stat -c %a "$state_root")" = 700 ] || fail "Hermes home is not private"
[ "$(stat -c %a "$state_root/.serve.env")" = 600 ] \
  || fail "session token file mode is not 0600"
token_hash="$(sha256sum "$state_root/.serve.env")"
grep -Eq '^HERMES_DASHBOARD_SESSION_TOKEN=[0-9a-f]{64}$' "$state_root/.serve.env" \
  || fail "session token file is malformed"
grep -Fq 'sync --locked --no-dev --python' "$tmp/uv.log" \
  || fail "uv sync is not locked or includes development dependencies"

pin_check="$tmp/root/usr/local/libexec/subyard-hermes-pin-check"
runtime_env="$tmp/root/etc/subyard/hermes-runtime.env"
HERMES_RUNTIME_ENV="$runtime_env" "$pin_check" --runtime-only \
  || fail "installed runtime-only pin check failed"
if HERMES_RUNTIME_ENV="$runtime_env" "$pin_check" >/dev/null 2>&1; then
  fail "pin check accepted a missing provider-ready marker"
fi
printf '%s\n' "$HERMES_COMMIT" > "$state_root/.provider-ready"
HERMES_RUNTIME_ENV="$runtime_env" "$pin_check" \
  || fail "commit-bound provider-ready marker was rejected"
printf '%s\n' 0000000000000000000000000000000000000000 \
  > "$install_root/.subyard-commit"
if HERMES_RUNTIME_ENV="$runtime_env" "$pin_check" --runtime-only >/dev/null 2>&1; then
  fail "pin check accepted a runtime commit mismatch"
fi
printf '%s\n' "$HERMES_COMMIT" > "$install_root/.subyard-commit"
rm -f "$state_root/.provider-ready"

curl_count="$(wc -l < "$tmp/curl.log")"
env "${common_env[@]}" bash "$HOOK" >/dev/null
[ "$(sha256sum "$state_root/.serve.env")" = "$token_hash" ] \
  || fail "re-provision rotated the session token"
[ "$(wc -l < "$tmp/curl.log")" -eq "$curl_count" ] \
  || fail "re-provision downloaded an already pinned runtime"

next_commit=1111111111111111111111111111111111111111
if env "${common_env[@]}" HERMES_COMMIT="$next_commit" bash "$HOOK" \
  >"$tmp/unverified-update.out" 2>&1; then
  fail "pin update proceeded without a verified backup"
fi
grep -Fq "pin update requires a verified backup of commit $HERMES_COMMIT" \
  "$tmp/unverified-update.out" || fail "unverified update error is unclear"
printf 'commit=%s\nsnapshot=fixture-old\n' "$HERMES_COMMIT" \
  > "$state_root/.last-verified-backup"
printf '%s\n' "$HERMES_COMMIT" > "$state_root/.provider-ready"
env "${common_env[@]}" HERMES_COMMIT="$next_commit" bash "$HOOK" >/dev/null
[ "$(<"$install_root/.subyard-commit")" = "$next_commit" ] \
  || fail "verified pin update did not install the reviewed commit"
[ ! -e "$state_root/.provider-ready" ] \
  || fail "pin update retained stale provider approval"

printf 'commit=%s\nsnapshot=fixture-new\n' "$next_commit" \
  > "$state_root/.last-verified-backup"
env "${common_env[@]}" bash "$HOOK" >/dev/null
[ "$(<"$install_root/.subyard-commit")" = "$HERMES_COMMIT" ] \
  || fail "verified rollback did not restore the exact old commit"

cat > "$tmp/bin/incus" <<'INCUS'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$HERMES_TEST_INCUS_ARGS"
tar -tf - > "$HERMES_TEST_BUNDLE_LOG"
INCUS
chmod +x "$tmp/bin/incus"
engine_env=(
  PATH="$tmp/bin:$PATH"
  HERMES_TEST_INCUS_ARGS="$tmp/incus.args"
  HERMES_TEST_BUNDLE_LOG="$tmp/bundle.log"
  SUBYARD_ENGINE_CONTEXT=1
  SUBYARD_ENGINE_CONTEXT_SCHEMA=1
  SUBYARD_OPERATOR_HOME="$tmp/home"
  SUBYARD_CONFIG_DIR="$tmp/config"
  SUBYARD_CONFIG_HOME="$tmp/config-home"
  SUBYARD_HOME="$ROOT"
  STORAGE_PATH="$tmp/storage"
  HOST_BASE="$tmp/host"
  RESTRICTED_DISK_PATHS=""
  YARD_TYPE=local
  INSTANCE_TYPE=container
  INSTANCE_NAME=yard-hermes
  INCUS_PROJECT=subyard-hermes
  INCUS_BRIDGE=incusbr0
  SSH_HOST=yard-hermes
  DEV_USER=dev
  DEV_UID=1000
  DEV_SUDO=1
  FORWARD_SSH_AGENT=0
  NESTED_E2E_VMS=0
)
env "${engine_env[@]}" bash "$ROOT/scripts/provision-profile.sh" hermes
grep -Fxq './provision.sh' "$tmp/bundle.log" \
  || fail "profile bundle omitted provision.sh"
grep -Fxq './hermes-serve.service' "$tmp/bundle.log" \
  || fail "profile bundle omitted the systemd unit"
grep -Fxq './hermes-backup-create' "$tmp/bundle.log" \
  || fail "profile bundle omitted a runtime helper"

printf 'ok: Hermes pinned provision and profile bundle\n'
