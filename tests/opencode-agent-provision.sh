#!/usr/bin/env bash
# OpenCode bootstrap checks with a fake installer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/config/agents/opencode/provision.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/fake-bin" "$tmp/system-bin" "$tmp/home" "$tmp/bin"

cat > "$tmp/fake-bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = -fsSL ]
[ -n "${2:-}" ]
cat <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
printf 'run\n' >> "$OPENCODE_TEST_COUNT"
printf '%s\n' "$*" > "$OPENCODE_TEST_ARGS"
mkdir -p "$HOME/.opencode/bin"
cat > "$HOME/.opencode/bin/opencode" <<'BIN'
#!/usr/bin/env bash
[ "$HOME" = "$OPENCODE_EXPECT_HOME" ] || exit 42
printf 'test-version\n'
BIN
chmod +x "$HOME/.opencode/bin/opencode"
INSTALLER
CURL
chmod +x "$tmp/fake-bin/curl"

export OPENCODE_TEST_COUNT="$tmp/install-count"
export OPENCODE_TEST_ARGS="$tmp/install-args"
export OPENCODE_EXPECT_HOME="$tmp/home"
common_env=(
  DEV_USER="$(id -un)"
  OPENCODE_INSTALL_HOME="$tmp/home"
  OPENCODE_BIN_LINK="$tmp/bin/opencode"
  OPENCODE_SYSTEM_PATH="$tmp/system-bin"
  OPENCODE_INSTALL_URL=https://opencode.ai/install
)

env PATH="$tmp/fake-bin:$PATH" "${common_env[@]}" bash "$HOOK" >/dev/null
[ -x "$tmp/home/.opencode/bin/opencode" ] || fail "official installer target is missing"
[ -L "$tmp/bin/opencode" ] || fail "yard-wide OpenCode link is missing"
[ "$(readlink "$tmp/bin/opencode")" = "$tmp/home/.opencode/bin/opencode" ] \
  || fail "yard-wide OpenCode link points to the wrong target"
[ "$(HOME="$tmp/home" "$tmp/bin/opencode" --version)" = test-version ] \
  || fail "installed CLI is not runnable in the dev user context"
[ "$(cat "$OPENCODE_TEST_ARGS")" = --no-modify-path ] \
  || fail "provision allowed the upstream installer to edit shell rc files"

# Re-provision is idempotent.
env PATH="$tmp/fake-bin:$PATH" "${common_env[@]}" bash "$HOOK" >/dev/null
[ "$(wc -l < "$OPENCODE_TEST_COUNT")" -eq 1 ] || fail "provision is not idempotent"

# Preserve a pre-existing executable.
mkdir -p "$tmp/existing-home" "$tmp/existing-bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/existing-bin/opencode"
chmod +x "$tmp/existing-bin/opencode"
env PATH="$tmp/fake-bin:$PATH" \
  DEV_USER="$(id -un)" \
  OPENCODE_INSTALL_HOME="$tmp/existing-home" \
  OPENCODE_BIN_LINK="$tmp/existing-bin/opencode" \
  OPENCODE_SYSTEM_PATH="$tmp/system-bin" \
  OPENCODE_INSTALL_URL=https://opencode.ai/install \
  bash "$HOOK" >/dev/null
[ ! -e "$tmp/existing-home/.opencode/bin/opencode" ] \
  || fail "provision replaced a pre-existing OpenCode install"
[ "$(wc -l < "$OPENCODE_TEST_COUNT")" -eq 1 ] \
  || fail "pre-existing OpenCode unexpectedly ran the installer"

printf 'ok: OpenCode agent provision\n'
