#!/usr/bin/env bash
# Shared CI/release gate for real pinned crypto and loopback OpenSSH adapters.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADAPTER_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/subyard-real-adapters.XXXXXX")"
trap 'rm -rf -- "$ADAPTER_ROOT"' EXIT

# shellcheck source=tests/helpers/test-context.sh
. "$ROOT/tests/helpers/test-context.sh"
setup_test_context "$ADAPTER_ROOT"
export HOME="$SUBYARD_OPERATOR_HOME"

# Keep the real artifact versions and checksums on the same source of truth as production.
unset \
  SUBYARD_AGE_VERSION \
  SUBYARD_AGE_SHA256_AMD64 \
  SUBYARD_AGE_SHA256_ARM64 \
  SUBYARD_SOPS_VERSION \
  SUBYARD_SOPS_SHA256_AMD64 \
  SUBYARD_SOPS_SHA256_ARM64
# shellcheck source=config/host.env
. "$ROOT/config/host.env"
export \
  SUBYARD_AGE_VERSION \
  SUBYARD_AGE_SHA256_AMD64 \
  SUBYARD_AGE_SHA256_ARM64 \
  SUBYARD_SOPS_VERSION \
  SUBYARD_SOPS_SHA256_AMD64 \
  SUBYARD_SOPS_SHA256_ARM64

export SUBYARD_KEYS_TOOLS_DIR="$ADAPTER_ROOT/tools"
export SUBYARD_REAL_KEYS_TOOLS_DIR="$SUBYARD_KEYS_TOOLS_DIR"
export ASSUME_YES=1
export TMPDIR="$ADAPTER_ROOT/tmp"

mkdir -p \
  "$SUBYARD_OPERATOR_HOME" \
  "$SUBYARD_CONFIG_DIR" \
  "$SUBYARD_CONFIG_HOME" \
  "$SUBYARD_HOME" \
  "$TMPDIR"

bash "$ROOT/scripts/install-key-tools.sh" --yes
bash "$ROOT/tests/real-host/credential-tools.sh"
bash "$ROOT/tests/real-host/ssh-rpc.sh"
bash "$ROOT/tests/real-host/ssh-credential-peer.sh"
