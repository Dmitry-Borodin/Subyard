#!/usr/bin/env bash
# Phase 3 convergence checks for the native ccusage binary.
# shellcheck disable=SC2034,SC2317 # state/functions are consumed by sourced init.sh probes
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v cc >/dev/null 2>&1 || fail "missing test dependency: cc"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"

build_binary() { # <version> <output>
  local version="$1" output="$2" source
  source="$tmp/ccusage-${version}.c"
  cat > "$source" <<EOF
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    puts("ccusage ${version}");
    return 0;
  }
  return 64;
}
EOF
  cc -O2 -o "$output" "$source"
}
build_binary 1.2.3 "$tmp/ccusage-correct"
build_binary 1.2.2 "$tmp/ccusage-wrong"

cat > "$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$tmp/bin/id" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
last=''
[ "$#" -eq 0 ] || last="${!#}"
if [ "$last" = "$MOCK_DEV_USER" ]; then
  case "${1:-}" in
    -u) exec /usr/bin/id -u ;;
    -g) exec /usr/bin/id -g ;;
    *) exit 0 ;;
  esac
fi
exec /usr/bin/id "$@"
SH
cat > "$tmp/bin/getent" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = passwd ] && [ -n "${2:-}" ]; then
  printf '%s:x:%s:%s::%s:/bin/bash\n' "$2" "$(id -u "$2")" "$(id -g "$2")" "$MOCK_DEV_HOME"
else
  exec /usr/bin/getent "$@"
fi
SH
chmod +x "$tmp/bin/docker" "$tmp/bin/id" "$tmp/bin/getent"
export MOCK_DEV_HOME="$tmp/home"
export MOCK_DEV_USER="subyard-ccusage-test-$$"
original_path="$PATH"

# Load the probe functions in isolation.
# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$tmp" test-project test-yard
SUBYARD_CONFIG_LOADED=1
DEV_UID="$(id -u)"
DEV_USER="$MOCK_DEV_USER"
HOST_LINKS=''
AGENTS=''
CCUSAGE_VERSION=1.2.3
CCUSAGE_INSTALL_PATH="$tmp/installed-ccusage"
CCUSAGE_EXPECTED_OWNER="$(id -u):$(id -g)"
# shellcheck source=scripts/init.sh
# shellcheck disable=SC1091
. "$ROOT/scripts/init.sh"

reconcile_incus_reachable() { return 0; }
reconcile_power_stopped() { return 1; }
stage_provision_agent_commands() { return 0; }
incus() {
  case "${1:-}" in
    config)
      [ "${2:-}" = get ] || return 90
      printf '%s\n' "${MOCK_CCUSAGE_MARKER:-}"
      ;;
    exec)
      shift
      local -a forwarded=()
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --env) forwarded+=("$2"); shift 2 ;;
          --) shift; break ;;
          *) shift ;;
        esac
      done
      env PATH="$tmp/bin:$original_path" "${forwarded[@]}" "$@"
      ;;
    *) return 90 ;;
  esac
}
MOCK_CCUSAGE_MARKER=1.2.3

expect_pending() {
  if stage_provision_check; then fail "$1 was accepted as converged"; fi
}
expect_done() {
  stage_provision_check || fail "$1 was not accepted as converged"
}

rm -f "$CCUSAGE_INSTALL_PATH"
expect_pending "missing ccusage"

cp "$tmp/ccusage-wrong" "$CCUSAGE_INSTALL_PATH"
chmod 0755 "$CCUSAGE_INSTALL_PATH"
expect_pending "wrong-version ccusage"

rm -f "$CCUSAGE_INSTALL_PATH"
ln -s "$tmp/ccusage-correct" "$CCUSAGE_INSTALL_PATH"
expect_pending "legacy ccusage symlink"

rm -f "$CCUSAGE_INSTALL_PATH"
cat > "$CCUSAGE_INSTALL_PATH" <<'WRAPPER'
#!/usr/bin/env bash
printf 'ccusage 1.2.3\n'
WRAPPER
chmod 0755 "$CCUSAGE_INSTALL_PATH"
expect_pending "regular npm wrapper"

cp "$tmp/ccusage-correct" "$CCUSAGE_INSTALL_PATH"
chmod 0644 "$CCUSAGE_INSTALL_PATH"
expect_pending "non-executable ccusage"

chmod 0777 "$CCUSAGE_INSTALL_PATH"
expect_pending "wrong-mode ccusage"

chmod 0755 "$CCUSAGE_INSTALL_PATH"
expect_done "exact standalone ccusage"

CCUSAGE_EXPECTED_OWNER=99999:99999
expect_pending "wrong-owner ccusage"
CCUSAGE_EXPECTED_OWNER="$(id -u):$(id -g)"
expect_done "restored binary owner"

CCUSAGE_VERSION=1.2.4
expect_pending "repository pin bump"
CCUSAGE_VERSION=1.2.3
expect_done "restored exact pin"

reconcile_power_stopped() { return 0; }
MOCK_CCUSAGE_MARKER=''
expect_pending "unmarked stopped yard"
MOCK_CCUSAGE_MARKER=1.2.3
expect_done "marked stopped yard"
CCUSAGE_VERSION=1.2.4
expect_pending "stopped yard pin bump"
CCUSAGE_VERSION=1.2.3
reconcile_power_stopped() { return 1; }

# Assert core hook wiring and an empty OpenClaw ownership surface.
grep -Fq 'CCUSAGE_PROVISION' "$ROOT/scripts/04-provision-subyard.sh" \
  || fail "Phase 3 does not invoke the core ccusage hook"
grep -Fq 'user.subyard.ccusage_version' "$ROOT/scripts/04-provision-subyard.sh" \
  || fail "Phase 3 does not record stopped-yard convergence"
pending_line="$(grep -n 'config set.*user.subyard.ccusage_version pending' "$ROOT/scripts/04-provision-subyard.sh" | cut -d: -f1)"
config_line="$(grep -n 'agent-configs.sh.*--yes' "$ROOT/scripts/04-provision-subyard.sh" | cut -d: -f1)"
commit_line="$(grep -n 'config set.*user.subyard.ccusage_version.*CCUSAGE_VERSION' "$ROOT/scripts/04-provision-subyard.sh" | cut -d: -f1)"
if [ "$pending_line" -ge "$config_line" ] || [ "$commit_line" -le "$config_line" ]; then
  fail "Phase 3 marker does not bracket the full operation"
fi
if grep -Riq 'ccusage' \
  "$ROOT/config/profiles/openclaw/profile.conf" \
  "$ROOT/config/profiles/openclaw/provision.sh"; then
  fail "OpenClaw still owns ccusage configuration or installation"
fi

printf 'ok: ccusage Phase 3 convergence\n'
