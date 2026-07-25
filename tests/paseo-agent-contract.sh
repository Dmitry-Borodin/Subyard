#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

agents="$(
  SUBYARD_CONFIG_DIR="$ROOT/config" \
    bash -c '. "$1"; printf "%s\n%s\n%s\n%s\n%s\n" \
      "$AGENTS" "$AGENT_paseo_PROVISION" "$AGENT_paseo_COMMAND" \
      "$AGENT_paseo_CHECK" "$AGENT_paseo_PROJECTS_CHANGED"' _ "$ROOT/config/agents.env"
)"
mapfile -t values <<<"$agents"
[[ " ${values[0]} " != *" paseo "* ]] || fail "Paseo entered the shipped default AGENTS"
[ "${values[1]}" = "$ROOT/config/agents/paseo/provision.sh" ] || fail "wrong Paseo provision hook"
[ "${values[2]}" = paseo ] || fail "wrong Paseo command"
[ "${values[3]}" = paseo-check ] || fail "wrong Paseo check"
[ "${values[4]}" = paseo-sync-projects ] || fail "wrong Paseo project hook"

jq -e '
  .version == 1 and .daemon.listen == "127.0.0.1:6767" and
  .daemon.relay == {
    enabled: true,
    endpoint: "relay.paseo.sh:443",
    publicEndpoint: "relay.paseo.sh:443",
    useTls: true,
    publicUseTls: true
  } and
  .app.baseUrl == "https://app.paseo.sh" and
  .features.webUi.enabled == false
' "$ROOT/config/agents/paseo/config.json" >/dev/null || fail "Paseo config contract drift"

lock="$ROOT/config/agents/paseo/bundle/package-lock.json"
[ "$(jq -r '.packages["node_modules/@getpaseo/cli"].version' "$lock")" = 0.2.1 ] \
  || fail "Paseo CLI lock drift"
[ "$(jq -r '.packages["node_modules/node-pty"].version' "$lock")" = 1.2.0-beta.11 ] \
  || fail "node-pty lock drift"
[ "$(jq -r '.packages["node_modules/sherpa-onnx-node"].version' "$lock")" = 1.12.28 ] \
  || fail "Sherpa lock drift"
jq -e '
  [.packages | to_entries[] |
    select(.key | endswith("/@anthropic-ai/claude-agent-sdk")) |
    .value.version] == ["0.3.214"]
' "$lock" >/dev/null || fail "Claude Agent SDK lock drift"

rg -q '^ExecStart=.*--listen 127[.]0[.]0[.]1:6767 .*--relay-use-tls .*--no-web-ui$' \
  "$ROOT/config/agents/paseo/paseo.service.in" || fail "unit listener/relay contract drift"
rg -q '^ReadWritePaths=@DEV_HOME@ /srv/agents/paseo /srv/workspaces$' \
  "$ROOT/config/agents/paseo/paseo.service.in" || fail "provider state is not writable"
! rg -qi 'updat|0[.]0[.]0[.]0|publicBaseUrl|serviceProxy' \
  "$ROOT/config/agents/paseo/paseo.service.in" || fail "unit enabled a forbidden surface"
rg -q 'PASEO_RELEASE_VERSION' "$ROOT/config/agents/paseo/provision.sh" \
  || fail "provision is not tied to the Subyard release"
rg -q 'files[.]sha256' "$ROOT/config/agents/paseo/provision.sh" \
  || fail "provision does not verify the deploy closure"
rg -q 'ubuntu-24[.]04-arm' "$ROOT/.github/workflows/release.yml" \
  || fail "release has no native arm64 Paseo lane"
rg -q 'AGENTS="claude codex opencode pi paseo"' "$ROOT/docs/paseo.md" \
  || fail "Paseo opt-in documentation is missing"
rg -q 'ssh yard-<name> -- paseo-pair' "$ROOT/docs/paseo.md" \
  || fail "Paseo pairing documentation is missing"

! rg -qi 'paseo' "$ROOT/config/commands.registry" "$ROOT/internal/cli" \
  "$ROOT/internal/domain" "$ROOT/internal/rpc" "$ROOT/scripts/04-provision-subyard.sh" \
  || fail "Paseo-specific core CLI/domain/RPC plumbing appeared"

printf 'PASS: Paseo remains an opt-in generic agent package\n'
