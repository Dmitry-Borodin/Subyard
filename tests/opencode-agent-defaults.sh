#!/usr/bin/env bash
# OpenCode default-config checks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing test dependency: $1"; }
need jq
need sha256sum

# The public policy contains no provider, model, or credentials.
policy="$ROOT/config/agents/opencode/opencode.jsonc"
jq -e '
  .permission["*"] == "allow" and
  .permission.bash["*"] == "allow" and
  .permission.bash["git commit"] == "ask" and
  .permission.bash["git commit *"] == "ask" and
  .permission.bash["git push"] == "ask" and
  .permission.bash["git push *"] == "ask" and
  (has("autoupdate") | not) and
  (has("provider") | not) and
  (has("model") | not)
' "$policy" >/dev/null || fail "OpenCode yard policy contract is invalid"

SUBYARD_CONFIG_DIR="$ROOT/config"
# shellcheck source=config/agents.env
. "$ROOT/config/agents.env"
[ "$AGENT_opencode_CONFIG" = "$policy" ] || fail "OpenCode template is not wired"
[ "$AGENT_opencode_CONFIG_DEST" = .config/opencode/opencode.jsonc ] \
  || fail "OpenCode config destination drifted"
[ "$AGENT_opencode_PROVISION" = "$ROOT/config/agents/opencode/provision.sh" ] \
  || fail "OpenCode provision hook is not wired"
[ "$AGENT_opencode_COMMAND" = opencode ] || fail "OpenCode convergence command drifted"
[ -x "$AGENT_opencode_PROVISION" ] || fail "OpenCode provision hook is not executable"
grep -Fq '_provision_var="AGENT_' "$ROOT/scripts/04-provision-subyard.sh" \
  || fail "Phase 3 does not discover agent provision hooks"
grep -Fq 'AGENT_COMMANDS' "$ROOT/scripts/reconcile/stages/provision.sh" \
  || fail "Phase 3 convergence does not check provisioned agent commands"
case "$AGENT_opencode_PERSIST" in
  *auth.json* | *'/log'* | *'/storage'*) fail "OpenCode secrets/logs/legacy storage are persisted" ;;
esac
case "$AGENT_opencode_PERSIST" in
  *'.local/share/opencode/opencode.db:/mnt/host/agent-sessions/opencode/opencode.db:file'*) ;;
  *) fail "OpenCode SQLite session database is not persisted" ;;
esac

# All public agent defaults gate commit and push.
jq -e '
  (.permissions.ask | index("Bash(git commit)")) != null and
  (.permissions.ask | index("Bash(git commit:*)")) != null and
  (.permissions.ask | index("Bash(git push)")) != null and
  (.permissions.ask | index("Bash(git push:*)")) != null
' "$ROOT/config/agents/claude/settings.json" >/dev/null || fail "Claude commit/push gates drifted"
for command in commit push; do
  grep -Fq "pattern = [\"git\", \"$command\"]" "$ROOT/config/agents/codex/rules/repo.rules" \
    || fail "Codex $command gate missing"
done
grep -Fq 'default_permissions = ":danger-full-access"' \
  "$ROOT/config/agents/codex/config.toml" \
  || fail "Codex yard permissions are not unrestricted"
if grep -Eq '^[[:space:]]*(sandbox_mode|\[sandbox_workspace_write\])' \
  "$ROOT/config/agents/codex/config.toml"; then
  fail "Codex yard config mixes permission profiles with legacy sandbox settings"
fi
grep -Fq 'HOST_OPENCODE_AGENTS_MD=' "$ROOT/config/host.env" \
  || fail "OpenCode host instructions are not configurable"
grep -Fq 'HOST_OPENCODE_AGENTS_MD' "$ROOT/scripts/agent-configs.sh" \
  || fail "OpenCode host instructions are not copied"
grep -Fq 'OPENCODE_AGENTS_REQ' "$ROOT/scripts/reconcile/stages/provision.sh" \
  || fail "OpenCode host instructions are not checked during convergence"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Refresh configs twice against a mocked yard.
# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$tmp"
export HOME="$tmp/home"
export SUBYARD_CONFIG_HOME="$tmp/state"
export SUBYARD_HOME="$tmp/data"
export SUBYARD_CONFIG_DIR="$tmp/config"
mkdir -p "$tmp/config" "$tmp/yard" "$tmp/host-instructions"
cp "$ROOT/config/agents.env" "$tmp/config/agents.env"
cp -R "$ROOT/config/agents" "$tmp/config/agents"
printf '%s\n' 'Claude host instructions' > "$tmp/host-instructions/CLAUDE.md"
printf '%s\n' 'Codex host instructions' > "$tmp/host-instructions/CODEX.md"
printf '%s\n' 'OpenCode host instructions' > "$tmp/host-instructions/OPENCODE.md"
export HOST_CLAUDE_MD="$tmp/host-instructions/CLAUDE.md"
export HOST_CODEX_AGENTS_MD="$tmp/host-instructions/CODEX.md"
export HOST_OPENCODE_AGENTS_MD="$tmp/host-instructions/OPENCODE.md"
refresh() {
  PATH="$ROOT/tests/fixtures/agent-configs-bin:$PATH" \
  MOCK_YARD_ROOT="$tmp/yard" \
  ASSUME_YES=1 \
    bash "$ROOT/scripts/agent-configs.sh" --yes >/dev/null
}
refresh
first="$(sha256sum \
  "$tmp/yard/home/dev/.claude/settings.json" \
  "$tmp/yard/home/dev/.codex/config.toml" \
  "$tmp/yard/home/dev/.codex/rules/repo.rules" \
  "$tmp/yard/home/dev/.config/opencode/opencode.jsonc" \
  "$tmp/yard/home/dev/.claude/CLAUDE.md" \
  "$tmp/yard/home/dev/.codex/AGENTS.md" \
  "$tmp/yard/home/dev/.config/opencode/AGENTS.md" \
  "$tmp/yard/home/dev/.pi/agent/settings.json")"
refresh
second="$(sha256sum \
  "$tmp/yard/home/dev/.claude/settings.json" \
  "$tmp/yard/home/dev/.codex/config.toml" \
  "$tmp/yard/home/dev/.codex/rules/repo.rules" \
  "$tmp/yard/home/dev/.config/opencode/opencode.jsonc" \
  "$tmp/yard/home/dev/.claude/CLAUDE.md" \
  "$tmp/yard/home/dev/.codex/AGENTS.md" \
  "$tmp/yard/home/dev/.config/opencode/AGENTS.md" \
  "$tmp/yard/home/dev/.pi/agent/settings.json")"
[ "$first" = "$second" ] || fail "agent config refresh is not idempotent"
cmp "$HOST_CLAUDE_MD" "$tmp/yard/home/dev/.claude/CLAUDE.md" \
  || fail "Claude host instructions were not copied verbatim"
cmp "$HOST_CODEX_AGENTS_MD" "$tmp/yard/home/dev/.codex/AGENTS.md" \
  || fail "Codex host instructions were not copied verbatim"
cmp "$HOST_OPENCODE_AGENTS_MD" "$tmp/yard/home/dev/.config/opencode/AGENTS.md" \
  || fail "OpenCode host instructions were not copied verbatim"
[ ! -e "$tmp/yard/home/dev/.local/share/opencode/auth.json" ] \
  || fail "config refresh copied OpenCode auth"

printf 'ok: OpenCode agent defaults\n'
