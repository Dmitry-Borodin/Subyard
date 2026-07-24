#!/usr/bin/env bash
# Host-free release artifact, checksum, atomic upgrade and rollback contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
release="$TMP/release"
export SUBYARD_OPERATOR_HOME="$TMP/home"
export SUBYARD_CONFIG_HOME="$TMP/config"
export SUBYARD_HOME="$TMP/data"

fail() { printf 'engine release: %s\n' "$*" >&2; exit 1; }
yard_update() { YARD_ENGINE_PATH="$release_engine" "$ROOT/bin/yard" update --yes "$@"; }

workflow="$ROOT/.github/workflows/release.yml"
[ -r "$workflow" ] || fail 'tag release workflow is missing'
grep -Fq 'contents: write' "$workflow" \
  && grep -Fq 'for arch in amd64 arm64' "$workflow" \
  && grep -Fq 'dev/release-assets.sh --release-dir .build/release' "$workflow" \
  && grep -Fq 'gh release create "$GITHUB_REF_NAME"' "$workflow" \
  || fail 'tag workflow does not publish both supported runtime architectures'

rpc_negotiate() { # <engine> <engine-version> <protocol-version> <compatible|incompatible> <label>
  local engine="$1" engine_version="$2" protocol="$3" expectation="$4" label="$5"
  local payload hex request response header size body
  payload="{\"version\":$protocol,\"type\":\"request\",\"id\":\"negotiate\",\"method\":\"rpc.negotiate\"}"
  hex="$(printf '%08x' "${#payload}")"
  request="$TMP/rpc-$label.request"; response="$TMP/rpc-$label.response"; body="$TMP/rpc-$label.json"
  {
    printf '%b' "\\x${hex:0:2}\\x${hex:2:2}\\x${hex:4:2}\\x${hex:6:2}"
    printf '%s' "$payload"
  } > "$request"
  SUBYARD_REPOSITORY_ROOT="$ROOT" SUBYARD_OPERATOR_HOME="$TMP/home" \
    SUBYARD_CONFIG_HOME="$TMP/config" SUBYARD_NO_AUDIT=1 \
    "$engine" rpc --stdio < "$request" > "$response"
  header="$(od -An -tx1 -N4 "$response" | tr -d ' \n')"
  [ "${#header}" -eq 8 ] || fail "$label returned no complete RPC frame header"
  case "$header" in *[!0-9a-f]*) fail "$label returned an invalid RPC frame header" ;; esac
  size=$((16#$header))
  [ "$(stat -c '%s' "$response")" -eq $((size + 4)) ] \
    || fail "$label returned a truncated or multi-frame negotiation response"
  dd if="$response" bs=1 skip=4 count="$size" status=none > "$body"
  case "$expectation" in
    compatible)
      jq -e '.version == 1 and .id == "negotiate" and .error == null and
        .result.version == 1 and .result.protocolMin == 1 and .result.protocolMax == 1 and
        .result.engineVersion == $engineVersion and
        (.result.capabilities | index("snapshot") != null)' \
        --arg engineVersion "$engine_version" "$body" >/dev/null \
        || fail "$label rejected the supported rolling RPC version" ;;
    incompatible)
      jq -e '.version == 1 and .id == "negotiate" and
        .error.code == "incompatible_version"' "$body" >/dev/null \
        || fail "$label did not reject an unsupported RPC version deterministically" ;;
    *) fail "invalid RPC expectation $expectation" ;;
  esac
}

staging_canary="$(mktemp --suffix=.env "$ROOT/config/staging/.package-canary.XXXXXX")"
qa_canary="$(mktemp "$ROOT/config/qa-pool/.package-canary.XXXXXX")"
untracked_canary="$ROOT/config/staging/.package-untracked-canary.txt"
printf 'ignored staging secret\n' > "$staging_canary"
printf 'ignored qa secret\n' > "$qa_canary"
printf 'untracked local input\n' > "$untracked_canary"
chmod 0600 "$staging_canary" "$qa_canary" "$untracked_canary"
trap 'rm -f -- "$staging_canary" "$qa_canary" "$untracked_canary"; rm -rf "$TMP"' EXIT
artifact_one="$("$ROOT/dev/package-engine.sh" --output-dir "$release" --version 1.0.0-test)"
bundle_one="$release/subyard-1.0.0-test-linux-amd64.tar.gz"
[ -x "$release/subyard-install.sh" ] \
  && [ -x "$release/subyard-install-runtime-release.sh" ] \
  && [ -r "$release/subyard-install-runtime-release.sh.sha256" ] \
  || fail 'standalone first-install assets are missing'
[ -x "$artifact_one" ] || { printf 'release artifact is not executable\n' >&2; exit 1; }
[ -r "$artifact_one.sha256" ] && [ -r "$artifact_one.manifest.json" ] && [ -r "$artifact_one.provenance.json" ] \
  || { printf 'release checksum, manifest or provenance missing\n' >&2; exit 1; }
[ -r "$bundle_one" ] && [ -r "$bundle_one.sha256" ] \
  && [ -r "$bundle_one.manifest.json" ] && [ -r "$bundle_one.provenance.json" ] \
  || fail 'self-contained runtime bundle contract is missing'
jq -e '.schemaVersion == 1 and .kind == "runtime" and .version == "1.0.0-test" and
  .rpc.min == 1 and .rpc.max == 1' "$bundle_one.manifest.json" >/dev/null \
  || fail 'runtime bundle manifest is incompatible'
bundle_list="$TMP/runtime-bundle.list"
tar -tzf "$bundle_one" > "$bundle_list"
grep -Fxq './bin/yard' "$bundle_list" \
  && grep -Fxq './bin/yard-engine' "$bundle_list" \
  && grep -Fxq './scripts/install-runtime-release.sh' "$bundle_list" \
  && grep -Fxq './config/commands.registry' "$bundle_list" \
  || fail 'runtime bundle does not contain the complete launcher contract'
grep -Fxq './runtime-files.sha256' "$bundle_list" \
  || fail 'runtime bundle exact file manifest is missing'
! grep -Fq "$(basename "$staging_canary")" "$bundle_list" \
  && ! grep -Fq "$(basename "$qa_canary")" "$bundle_list" \
  && ! grep -Fq "$(basename "$untracked_canary")" "$bundle_list" \
  || fail 'runtime bundle contains an untracked host-local canary'
bundle_extract="$TMP/bundle-extract"
install -d "$bundle_extract"
tar -xzf "$bundle_one" -C "$bundle_extract"
(
  cd "$bundle_extract"
  sha256sum -c runtime-files.sha256 >/dev/null
  find . -type f ! -name runtime-files.sha256 -print | sort > "$TMP/bundle-actual.list"
  sed -E 's/^[0-9a-fA-F]{64}  //' runtime-files.sha256 | sort > "$TMP/bundle-declared.list"
)
cmp -s "$TMP/bundle-actual.list" "$TMP/bundle-declared.list" \
  || fail 'runtime bundle file manifest is not exact'
for excluded in update-engine.sh power-state.sh bootstrap-runtime.sh build-engine.sh package-engine.sh install-cli.sh; do
  ! grep -Fq "/$excluded" "$bundle_list" \
    || fail "runtime bundle contains non-runtime script $excluded"
done
jq -e '.schemaVersion == 1 and .version == "1.0.0-test" and .rpc.min == 1 and .rpc.max == 1 and
  .projectStateSchema == 1 and .credentialSchema == 1' "$artifact_one.manifest.json" >/dev/null
jq -e '.schemaVersion == 1 and .version == "1.0.0-test" and
  .sourceRepository == "github.com/Dmitry-Borodin/Subyard" and (.sha256 | length == 64)' \
  "$artifact_one.provenance.json" >/dev/null
rpc_negotiate "$artifact_one" 1.0.0-test 1 compatible artifact-one-v1
rpc_negotiate "$artifact_one" 1.0.0-test 2 incompatible artifact-one-v2

standalone_home="$TMP/standalone-home"
standalone_bin="$TMP/standalone-bin"
standalone_no_go="$TMP/standalone-no-go"
install -d "$standalone_home" "$standalone_bin" "$standalone_no_go"
cat > "$standalone_no_go/go" <<EOF
#!/bin/sh
touch '$TMP/standalone-go-invoked'
exit 99
EOF
chmod 0700 "$standalone_no_go/go"
if HOME="$TMP/unconfirmed-home" YARD_RUNTIME_ROOT="$TMP/unconfirmed-runtime" \
  YARD_RELEASE_BASE_URL="file://$release" YARD_RELEASE_VERSION=1.0.0-test \
  "$release/subyard-install.sh" </dev/null >/dev/null 2>&1; then
  fail 'standalone bootstrap changed the host without confirmation'
fi
[ ! -e "$TMP/unconfirmed-runtime" ] \
  || fail 'declined standalone bootstrap created a runtime'
HOME="$standalone_home" SUBYARD_HOME="$standalone_home/.subyard" \
  SUBYARD_CONFIG_HOME="$standalone_home/.config/subyard" YARD_BIN_DIR="$standalone_bin" \
  YARD_SHELL_RC="$standalone_home/.bashrc" YARD_LOGIN_RC="$standalone_home/.profile" \
  YARD_RELEASE_BASE_URL="file://$release" YARD_RELEASE_VERSION=1.0.0-test \
  PATH="$standalone_no_go:$PATH" \
  "$release/subyard-install.sh" --yes >/dev/null
[ "$($standalone_bin/yard --version)" = 'yard 1.0.0-test' ] \
  && [ -L "$standalone_bin/sy" ] && [ ! -e "$TMP/standalone-go-invoked" ] \
  || fail 'standalone installer did not publish a usable runtime without a checkout'
grep -Fq 'Subyard CLI login PATH' "$standalone_home/.profile" \
  && grep -Fq 'Subyard CLI interactive PATH' "$standalone_home/.bashrc" \
  && grep -Fq 'Subyard CLI completion' "$standalone_home/.bashrc" \
  || fail 'standalone installer did not configure new login and interactive shells'
HOME="$standalone_home" PATH=/usr/bin:/bin SHELL=/bin/bash bash -lc \
  'command -v yard >/dev/null && yard --version >/dev/null' \
  || fail 'standalone installer is not available to a new login shell'
HOME="$standalone_home" PATH=/usr/bin:/bin SHELL=/bin/bash \
  bash --noprofile --rcfile "$standalone_home/.bashrc" -ic \
  'command -v yard >/dev/null && complete -p yard >/dev/null' >/dev/null 2>&1 \
  || fail 'standalone installer did not activate Bash completion'
HOME="$standalone_home" SUBYARD_HOME="$standalone_home/.subyard" \
  SUBYARD_CONFIG_HOME="$standalone_home/.config/subyard" YARD_BIN_DIR="$standalone_bin" \
  YARD_SHELL_RC="$standalone_home/.bashrc" YARD_LOGIN_RC="$standalone_home/.profile" \
  YARD_RELEASE_BASE_URL="file://$release" YARD_RELEASE_VERSION=1.0.0-test \
  PATH="$standalone_no_go:$PATH" \
  "$release/subyard-install.sh" --yes >/dev/null
[ "$(grep -cF 'Subyard CLI login PATH' "$standalone_home/.profile")" -eq 1 ] \
  && [ "$(grep -cF 'Subyard CLI interactive PATH' "$standalone_home/.bashrc")" -eq 1 ] \
  && [ "$(grep -cF 'Subyard CLI completion' "$standalone_home/.bashrc")" -eq 1 ] \
  || fail 'standalone shell integration is not idempotent'

bad_release="$TMP/bad-standalone-release"
cp -a "$release" "$bad_release"
printf 'corrupt\n' >> "$bad_release/subyard-install-runtime-release.sh"
if HOME="$TMP/bad-standalone-home" YARD_RUNTIME_ROOT="$TMP/bad-standalone-runtime" \
  YARD_RELEASE_BASE_URL="file://$bad_release" YARD_RELEASE_VERSION=1.0.0-test \
  "$bad_release/subyard-install.sh" --yes >/dev/null 2>&1; then
  fail 'standalone bootstrap accepted a corrupt installer'
fi
[ ! -e "$TMP/bad-standalone-runtime/current" ] \
  || fail 'corrupt standalone installer changed the current runtime'

artifact_arm="$("$ROOT/dev/package-engine.sh" --output-dir "$release" --version 1.0.0-test --arch arm64)"
jq -e '.os == "linux" and .arch == "arm64" and .version == "1.0.0-test"' \
  "$artifact_arm.manifest.json" >/dev/null \
  || fail 'arm64 release contract was not published'
printf 'must not be published\n' > "$release/unexpected-build-note"
publish_list="$TMP/publish-assets.list"
"$ROOT/dev/release-assets.sh" --release-dir "$release" --version 1.0.0-test > "$publish_list"
[ "$(wc -l < "$publish_list")" -eq 19 ] \
  && ! grep -Fq '.build.lock' "$publish_list" \
  && ! grep -Fq 'unexpected-build-note' "$publish_list" \
  || fail 'release publishing does not use the exact 19-asset allowlist'
while IFS= read -r publish_asset; do
  [ -f "$publish_asset" ] && [ ! -L "$publish_asset" ] \
    || fail "release allowlist contains an invalid asset: $publish_asset"
done < "$publish_list"

legacy_state="$SUBYARD_CONFIG_HOME/projects/legacy-12345678.json"
install -d -m 0700 "$(dirname "$legacy_state")"
printf '%s\n' '{"schema":1,"projectId":"legacy-12345678","name":"Legacy","hostPath":"/host/Legacy","yardPath":"/srv/workspaces/legacy-12345678/src","mode":"sync","sshHost":"yard"}' > "$legacy_state"
chmod 0664 "$legacy_state"

artifact_two="$("$ROOT/dev/package-engine.sh" --output-dir "$release" --version 1.1.0-test)"
bundle_two="$release/subyard-1.1.0-test-linux-amd64.tar.gz"
release_engine="$artifact_two"
jq -e '.version == "1.1.0-test" and .rpc.min == 1 and .rpc.max == 1' \
  "$artifact_two.manifest.json" >/dev/null
rpc_negotiate "$artifact_two" 1.1.0-test 1 compatible artifact-two-v1

# The public updater publishes a complete runtime, atomically switches stable links and can reuse
# its exact cache offline without touching a working current release.
runtime_root="$TMP/update-runtime"
YARD_RELEASE_BASE_URL="file://$release" YARD_RELEASE_CACHE="$TMP/cache" \
  yard_update --runtime-root "$runtime_root" --version 1.0.0-test >/dev/null
[ "$("$runtime_root/current/bin/yard" --version | awk '{print $2}')" = 1.0.0-test ] \
  || fail 'yard update did not install the selected release'
[ "$(stat -c '%a' "$legacy_state")" = 600 ] \
  || fail 'runtime install did not migrate legacy project permissions'
[ -x "$runtime_root/current/scripts/install-runtime-release.sh" ] \
  && [ -r "$runtime_root/current/config/commands.registry" ] \
  && [ -r "$runtime_root/current/completions/yard.bash" ] \
  || fail 'yard update installed an incomplete runtime'
YARD_RELEASE_CACHE="$TMP/cache" yard_update \
  --runtime-root "$runtime_root" --version 1.0.0-test --offline --check >/dev/null \
  || fail 'offline update check did not use the verified cache'
cached_bundle="$TMP/cache/1.0.0-test/$(basename "$bundle_one")"
printf 'truncated\n' >> "$cached_bundle"
if YARD_RELEASE_CACHE="$TMP/cache" yard_update \
  --runtime-root "$runtime_root" --version 1.0.0-test --offline --check >/dev/null 2>&1; then
  fail 'offline update check accepted a corrupt cached bundle'
fi
[ "$("$runtime_root/current/bin/yard" --version | awk '{print $2}')" = 1.0.0-test ] \
  || fail 'failed offline check changed the current runtime'

partial="$TMP/partial"; install -d "$partial"
install -m 0644 "$bundle_two" "$partial/$(basename "$bundle_two")"
install -m 0644 "$bundle_two.sha256" "$bundle_two.manifest.json" "$partial/"
if YARD_RELEASE_BASE_URL="file://$partial" YARD_RELEASE_CACHE="$TMP/partial-cache" \
  yard_update --runtime-root "$runtime_root" --version 1.1.0-test >/dev/null 2>&1; then
  fail 'incomplete release unexpectedly installed'
fi
[ "$("$runtime_root/current/bin/yard" --version | awk '{print $2}')" = 1.0.0-test ] \
  || fail 'interrupted/incomplete update replaced the current runtime'

YARD_RELEASE_BASE_URL="file://$release" YARD_RELEASE_CACHE="$TMP/cache" \
  yard_update --runtime-root "$runtime_root" --version 1.1.0-test >/dev/null
[ "$("$runtime_root/current/bin/yard" --version | awk '{print $2}')" = 1.1.0-test ] \
  || fail 'runtime upgrade did not switch current'
[ "$("$runtime_root/previous/bin/yard" --version | awk '{print $2}')" = 1.0.0-test ] \
  || fail 'runtime upgrade did not retain previous'
yard_update --runtime-root "$runtime_root" --rollback >/dev/null
[ "$("$runtime_root/current/bin/yard" --version | awk '{print $2}')" = 1.0.0-test ] \
  || fail 'runtime rollback did not restore previous'
[ "$("$runtime_root/previous/bin/yard" --version | awk '{print $2}')" = 1.1.0-test ] \
  || fail 'runtime rollback did not retain the replaced release'

printf 'ok: release publishing and runtimes are verified, offline-safe, atomic and rollback-capable\n'
