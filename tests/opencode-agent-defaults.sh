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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Refresh configs twice against a mocked yard.
mkdir -p "$tmp/config" "$tmp/yard"
cp "$ROOT/config/agents.env" "$tmp/config/agents.env"
cp -R "$ROOT/config/agents" "$tmp/config/agents"
refresh() {
  PATH="$ROOT/tests/fixtures/agent-configs-bin:$PATH" \
  MOCK_YARD_ROOT="$tmp/yard" \
  SUBYARD_CONFIG_DIR="$tmp/config" \
  ASSUME_YES=1 \
    bash "$ROOT/scripts/agent-configs.sh" --yes >/dev/null
}
refresh
first="$(sha256sum \
  "$tmp/yard/home/dev/.claude/settings.json" \
  "$tmp/yard/home/dev/.codex/config.toml" \
  "$tmp/yard/home/dev/.codex/rules/repo.rules" \
  "$tmp/yard/home/dev/.config/opencode/opencode.jsonc" \
  "$tmp/yard/home/dev/.pi/agent/settings.json")"
refresh
second="$(sha256sum \
  "$tmp/yard/home/dev/.claude/settings.json" \
  "$tmp/yard/home/dev/.codex/config.toml" \
  "$tmp/yard/home/dev/.codex/rules/repo.rules" \
  "$tmp/yard/home/dev/.config/opencode/opencode.jsonc" \
  "$tmp/yard/home/dev/.pi/agent/settings.json")"
[ "$first" = "$second" ] || fail "agent config refresh is not idempotent"
[ ! -e "$tmp/yard/home/dev/.local/share/opencode/auth.json" ] \
  || fail "config refresh copied OpenCode auth"

printf 'ok: OpenCode agent defaults\n'
