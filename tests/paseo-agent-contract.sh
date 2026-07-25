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

for workflow in ci.yml release.yml; do
  grep -Eq 'apt-get install .* ripgrep( |$)' "$ROOT/.github/workflows/$workflow" \
    || fail "$workflow does not install the ripgrep test dependency"
done

rg -q '^ExecStart=.*--listen 127[.]0[.]0[.]1:6767 .*--relay-use-tls .*--no-web-ui$' \
  "$ROOT/config/agents/paseo/paseo.service.in" || fail "unit listener/relay contract drift"
rg -q '^ExecStartPost=/usr/local/bin/paseo-sync-projects --wait --force$' \
  "$ROOT/config/agents/paseo/paseo.service.in" || fail "startup sync has no bounded readiness wait"
rg -q '^ReadWritePaths=@DEV_HOME@ /srv/agents/paseo /srv/workspaces$' \
  "$ROOT/config/agents/paseo/paseo.service.in" || fail "provider state is not writable"
! rg -qi 'updat|0[.]0[.]0[.]0|publicBaseUrl|serviceProxy' \
  "$ROOT/config/agents/paseo/paseo.service.in" || fail "unit enabled a forbidden surface"
rg -q 'PASEO_RELEASE_VERSION' "$ROOT/config/agents/paseo/provision.sh" \
  || fail "provision is not tied to the Subyard release"
rg -q 'files[.]sha256' "$ROOT/config/agents/paseo/provision.sh" \
  || fail "provision does not verify the deploy closure"
rg -q 'PASEO_HEALTH_WAIT_SECONDS' "$ROOT/config/agents/paseo/bin/paseo-check" \
  || fail "readiness has no bounded local health wait"
rg -q 'ubuntu-24[.]04-arm' "$ROOT/.github/workflows/release.yml" \
  || fail "release has no native arm64 Paseo lane"
rg -q 'AGENTS="claude codex opencode pi paseo"' "$ROOT/docs/paseo.md" \
  || fail "Paseo opt-in documentation is missing"
rg -q 'ssh yard-<name> -- paseo-pair' "$ROOT/docs/paseo.md" \
  || fail "Paseo pairing documentation is missing"

! rg -qi 'paseo' "$ROOT/config/commands.registry" "$ROOT/internal/cli" \
  "$ROOT/internal/domain" "$ROOT/internal/rpc" "$ROOT/scripts/04-provision-subyard.sh" \
  || fail "Paseo-specific core CLI/domain/RPC plumbing appeared"

wrapper_temp="$(mktemp -d)"
cleanup_wrapper() { rm -rf -- "$wrapper_temp"; }
trap cleanup_wrapper EXIT HUP INT TERM
mkdir -p "$wrapper_temp/bin" "$wrapper_temp/runtime/node/bin" \
  "$wrapper_temp/runtime/app/libexec" "$wrapper_temp/home"
ln -s "$wrapper_temp/runtime" "$wrapper_temp/current"
touch "$wrapper_temp/runtime/app/libexec/paseo-sync-projects.mjs"
cat >"$wrapper_temp/runtime/node/bin/node" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >"$PASEO_FAKE_NODE_LOG"
SH
cat >"$wrapper_temp/bin/curl" <<'SH'
#!/bin/sh
count=0
[ ! -r "$PASEO_FAKE_CURL_STATE" ] || count="$(cat "$PASEO_FAKE_CURL_STATE")"
count=$((count + 1))
printf '%s\n' "$count" >"$PASEO_FAKE_CURL_STATE"
[ "${PASEO_FAKE_CURL_NEVER:-0}" != 1 ] && [ "$count" -ge 3 ]
SH
chmod 0755 "$wrapper_temp/runtime/node/bin/node" "$wrapper_temp/bin/curl"
PASEO_FAKE_CURL_STATE="$wrapper_temp/curl-count" \
PASEO_FAKE_NODE_LOG="$wrapper_temp/node.log" \
PASEO_INSTALL_ROOT="$wrapper_temp/current" PASEO_HOME="$wrapper_temp/home" \
PASEO_SYNC_WAIT_SECONDS=5 PATH="$wrapper_temp/bin:$PATH" \
  "$ROOT/config/agents/paseo/bin/paseo-sync-projects" --wait --force
[ "$(cat "$wrapper_temp/curl-count")" -eq 3 ] \
  && grep -Fq 'paseo-sync-projects.mjs --force' "$wrapper_temp/node.log" \
  || fail "startup sync did not wait for health or consumed the wrong arguments"
rm -f "$wrapper_temp/node.log" "$wrapper_temp/curl-count"
if PASEO_FAKE_CURL_NEVER=1 PASEO_FAKE_CURL_STATE="$wrapper_temp/curl-count" \
  PASEO_FAKE_NODE_LOG="$wrapper_temp/node.log" \
  PASEO_INSTALL_ROOT="$wrapper_temp/current" PASEO_HOME="$wrapper_temp/home" \
  PASEO_SYNC_WAIT_SECONDS=1 PATH="$wrapper_temp/bin:$PATH" \
    "$ROOT/config/agents/paseo/bin/paseo-sync-projects" --wait --force >/dev/null 2>&1; then
  fail "startup sync accepted a daemon that never became healthy"
fi
[ ! -e "$wrapper_temp/node.log" ] || fail "startup sync ran after its health deadline"

printf 'PASS: Paseo remains an opt-in generic agent package\n'
