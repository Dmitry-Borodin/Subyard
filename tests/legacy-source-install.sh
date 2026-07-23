#!/usr/bin/env bash
# Host-free pre-Go source-link migration, config import and one-time recovery contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'find "$TMP" -depth -delete' EXIT
fail() { printf 'legacy-source-install: %s\n' "$*" >&2; exit 1; }

home="$TMP/home"
source_root="$home/Subyard"
bin_dir="$home/.local/bin"
data_home="$home/.subyard"
config_home="$home/.config/subyard"
release="$TMP/release"
install -d "$source_root/bin" "$source_root/scripts" "$source_root/config" \
  "$source_root/completions" "$source_root/private/yards" \
  "$source_root/private/agents/codex" "$bin_dir" "$config_home/yards/named/projects" \
  "$home/custom-projects"
chmod 0700 "$config_home" "$config_home/yards" "$config_home/yards/named" \
  "$config_home/yards/named/projects" "$home/custom-projects"
printf '%s\n' '#!/usr/bin/env bash' '# historical thin dispatcher over scripts/' \
  'printf "yard 0.1.0-dev\n"' > "$source_root/bin/yard"
chmod 0755 "$source_root/bin/yard"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$source_root/scripts/install-cli.sh"
chmod 0755 "$source_root/scripts/install-cli.sh"
printf 'fixture\n' > "$source_root/config/commands.registry"
printf 'complete fixture\n' > "$source_root/completions/yard.bash"
printf 'fixture rule\n' > "$source_root/private/agents/codex/repo.rules"
printf '%s\n' \
  'DEV_SUDO=1' \
  'MIGRATION_SENTINEL=machine-private-value' \
  'SUBYARD_STATE_DIR="$HOME/custom-projects"' \
  'AGENT_codex_RULES="$SUBYARD_CONFIG_DIR/../private/agents/codex/repo.rules"' \
  > "$source_root/private/config.env"
printf 'SSH_PORT=3333\n' > "$source_root/private/yards/named.env"
chmod 0600 "$source_root/private/config.env" "$source_root/private/yards/named.env"
ln -s "$source_root/bin/yard" "$bin_dir/yard"
ln -s "$source_root/bin/yard" "$bin_dir/sy"

rc="$home/.bashrc"
login_rc="$home/.profile"
printf '%s\n' \
  '# unrelated interactive setting' \
  'export KEEP_ME=1' \
  '# Subyard CLI' \
  "export PATH=\"$bin_dir:\$PATH\"" \
  '# Subyard CLI completion' \
  "[ -f \"$source_root/completions/yard.bash\" ] && source \"$source_root/completions/yard.bash\"" \
  > "$rc"
printf '%s\n' '# unrelated login setting' 'export LOGIN_KEEP=1' > "$login_rc"
rc_before="$(sha256sum "$rc" | cut -d' ' -f1)"
login_before="$(sha256sum "$login_rc" | cut -d' ' -f1)"

legacy_default="$home/custom-projects/default-12345678.json"
legacy_named="$config_home/yards/named/projects/named-12345678.json"
printf '%s\n' \
  '{"schema":1,"projectId":"default-12345678","name":"Default","hostPath":"/host/default","yardPath":"/srv/workspaces/default-12345678/src","mode":"sync","sshHost":"yard"}' \
  > "$legacy_default"
printf '%s\n' \
  '{"schema":1,"projectId":"named-12345678","name":"Named","hostPath":"/host/named","yardPath":"/srv/workspaces/named-12345678/src","mode":"sync","sshHost":"yard-named"}' \
  > "$legacy_named"
chmod 0664 "$legacy_default" "$legacy_named"

"$ROOT/dev/package-engine.sh" --output-dir "$release" --version 9.0.0-legacy-test >/dev/null
HOME="$home" SUBYARD_HOME="$data_home" YARD_BIN_DIR="$bin_dir" \
  YARD_SHELL_RC="$rc" YARD_LOGIN_RC="$login_rc" \
  YARD_RELEASE_BASE_URL="file://$release" YARD_RELEASE_VERSION=9.0.0-legacy-test \
  "$release/subyard-install.sh" --yes > "$TMP/install.out"
grep -Fq 'migrate a recognized pre-Go install' "$TMP/install.out" \
  || fail 'bootstrap did not announce the conditional source migration before changing the host'

runtime_launcher="$data_home/runtime/current/bin/yard"
[ "$(readlink "$bin_dir/yard")" = "$runtime_launcher" ] \
  && [ "$(readlink "$bin_dir/sy")" = "$runtime_launcher" ] \
  || fail 'bootstrap did not atomically replace both source entrypoints'
[ "$("$bin_dir/yard" --version)" = 'yard 9.0.0-legacy-test' ] \
  || fail 'migrated runtime is not executable'
[ -x "$source_root/bin/yard" ] \
  || fail 'migration removed the historical checkout'
cmp -s "$source_root/private/config.env" "$data_home/config.env" \
  || fail 'legacy global overlay was not imported'
cmp -s "$source_root/private/yards/named.env" "$config_home/yards/named.env" \
  || fail 'legacy named-yard registration was not imported'
cmp -s "$source_root/private/agents/codex/repo.rules" \
  "$data_home/operator-overlay/private/agents/codex/repo.rules" \
  || fail 'legacy private agent asset was not imported outside the runtime'
default_mode="$(stat -c '%a' "$legacy_default")"
named_mode="$(stat -c '%a' "$legacy_named")"
[ "$default_mode" = 600 ] && [ "$named_mode" = 600 ] \
  || fail "default, explicit or named project state was not migrated (default=$default_mode named=$named_mode)"
grep -Fq "$data_home/runtime/current/completions/yard.bash" "$rc" \
  && ! grep -Fq "$source_root/completions/yard.bash" "$rc" \
  || fail 'legacy completion block was not rewritten to the stable runtime'
[ "$(grep -Fc '# Subyard CLI completion' "$rc")" = 1 ] \
  && grep -Fq 'export KEEP_ME=1' "$rc" \
  && grep -Fq 'export LOGIN_KEEP=1' "$login_rc" \
  || fail 'shell migration changed unrelated content or duplicated its marker'
if grep -R -Fq 'machine-private-value' "$data_home/runtime"; then
  fail 'operator config leaked into the immutable runtime'
fi

recovery="$data_home/recovery/pre-go-source"
[ -x "$recovery/restore.sh" ] || fail 'one-time source recovery was not published'
HOME="$home" SUBYARD_HOME="$data_home" "$recovery/restore.sh" >/dev/null
[ "$(readlink -f "$bin_dir/yard")" = "$source_root/bin/yard" ] \
  && [ "$(readlink -f "$bin_dir/sy")" = "$source_root/bin/yard" ] \
  || fail 'source recovery did not restore both historical entrypoints'
[ "$(sha256sum "$rc" | cut -d' ' -f1)" = "$rc_before" ] \
  && [ "$(sha256sum "$login_rc" | cut -d' ' -f1)" = "$login_before" ] \
  || fail 'source recovery did not restore exact pre-migration shell files'
[ ! -e "$data_home/config.env" ] && [ ! -e "$config_home/yards/named.env" ] \
  && [ ! -e "$data_home/operator-overlay/private/agents/codex/repo.rules" ] \
  || fail 'source recovery left imported machine configuration behind'
[ -x "$data_home/runtime/current/bin/yard" ] \
  || fail 'source recovery destroyed the verified runtime'

printf 'ambiguous\n' > "$bin_dir/sy.new"
mv -f "$bin_dir/sy.new" "$bin_dir/sy"
if HOME="$home" "$data_home/runtime/current/scripts/migrate-source-install.sh" \
  --runtime-root "$data_home/runtime" --bin-dir "$bin_dir" --rc "$rc" --login-rc "$login_rc" \
  --data-home "$data_home" >/dev/null 2>&1; then
  fail 'legacy detector accepted an ambiguous regular sy entrypoint'
fi
[ "$(readlink -f "$bin_dir/yard")" = "$source_root/bin/yard" ] \
  || fail 'failed detector changed the valid yard entrypoint'

printf 'ok: pre-Go source install migrates atomically and retains guarded source recovery\n'
