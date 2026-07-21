#!/usr/bin/env bash
# Host-free release artifact, checksum, atomic upgrade and rollback contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
release="$TMP/release"; target="$TMP/install/yard-engine"

fail() { printf 'engine release: %s\n' "$*" >&2; exit 1; }

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

artifact_one="$("$ROOT/scripts/package-engine.sh" --output-dir "$release" --version 1.0.0-test)"
[ -x "$artifact_one" ] || { printf 'release artifact is not executable\n' >&2; exit 1; }
[ -r "$artifact_one.sha256" ] && [ -r "$artifact_one.manifest.json" ] \
  || { printf 'release checksum or manifest missing\n' >&2; exit 1; }
jq -e '.schemaVersion == 1 and .version == "1.0.0-test" and .rpc.min == 1 and .rpc.max == 1 and
  .projectStateSchema == 1 and .credentialSchema == 1' "$artifact_one.manifest.json" >/dev/null
rpc_negotiate "$artifact_one" 1.0.0-test 1 compatible artifact-one-v1
rpc_negotiate "$artifact_one" 1.0.0-test 2 incompatible artifact-one-v2

"$ROOT/scripts/install-engine-release.sh" --target "$target" \
  --artifact "$artifact_one" --checksum "$artifact_one.sha256" >/dev/null
[ "$(SUBYARD_REPOSITORY_ROOT="$ROOT" "$target" --version | awk '{print $2}')" = '1.0.0-test' ] \
  || { printf 'first release version mismatch\n' >&2; exit 1; }

bad_checksum="$TMP/bad.sha256"
printf '%064d  bad\n' 0 > "$bad_checksum"
if "$ROOT/scripts/install-engine-release.sh" --target "$target" \
  --artifact "$artifact_one" --checksum "$bad_checksum" >/dev/null 2>&1; then
  printf 'checksum mismatch unexpectedly installed\n' >&2; exit 1
fi
[ "$(SUBYARD_REPOSITORY_ROOT="$ROOT" "$target" --version | awk '{print $2}')" = '1.0.0-test' ] \
  || { printf 'checksum failure replaced current engine\n' >&2; exit 1; }

artifact_two="$("$ROOT/scripts/package-engine.sh" --output-dir "$release" --version 1.1.0-test)"
jq -e '.version == "1.1.0-test" and .rpc.min == 1 and .rpc.max == 1' \
  "$artifact_two.manifest.json" >/dev/null
rpc_negotiate "$artifact_two" 1.1.0-test 1 compatible artifact-two-v1
"$ROOT/scripts/install-engine-release.sh" --target "$target" \
  --artifact "$artifact_two" --checksum "$artifact_two.sha256" >/dev/null
[ "$(SUBYARD_REPOSITORY_ROOT="$ROOT" "$target" --version | awk '{print $2}')" = '1.1.0-test' ] \
  || { printf 'upgrade version mismatch\n' >&2; exit 1; }
[ "$(SUBYARD_REPOSITORY_ROOT="$ROOT" "$target.previous" --version | awk '{print $2}')" = '1.0.0-test' ] \
  || { printf 'previous release was not retained\n' >&2; exit 1; }
rpc_negotiate "$target" 1.1.0-test 1 compatible installed-upgrade-v1

printf '#!/bin/sh\nexit 1\n' > "$target.previous"
chmod 0755 "$target.previous"
if "$ROOT/scripts/install-engine-release.sh" --target "$target" --rollback >/dev/null 2>&1; then
  fail 'rollback accepted a previous engine that failed its self-check'
fi
[ "$(SUBYARD_REPOSITORY_ROOT="$ROOT" "$target" --version | awk '{print $2}')" = '1.1.0-test' ] \
  || fail 'failed rollback replaced the current engine'
install -m 0755 "$artifact_one" "$target.previous"

"$ROOT/scripts/install-engine-release.sh" --target "$target" --rollback >/dev/null
[ "$(SUBYARD_REPOSITORY_ROOT="$ROOT" "$target" --version | awk '{print $2}')" = '1.0.0-test' ] \
  || { printf 'rollback did not restore previous release\n' >&2; exit 1; }
[ "$(SUBYARD_REPOSITORY_ROOT="$ROOT" "$target.previous" --version | awk '{print $2}')" = '1.1.0-test' ] \
  || { printf 'rollback did not retain replaced release\n' >&2; exit 1; }
rpc_negotiate "$target" 1.0.0-test 1 compatible installed-rollback-v1

printf 'ok: engine release is versioned, checksum-verified, atomic and rollback-capable\n'
