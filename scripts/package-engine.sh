#!/usr/bin/env bash
# Build a versioned Linux engine artifact with a detached SHA-256 and compatibility manifest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$REPO/.build/release"
VERSION="${YARD_BUILD_VERSION:-0.1.0-dev}"

while [ $# -gt 0 ]; do
  case "$1" in
    --output-dir) [ $# -ge 2 ] || { printf 'package-engine: --output-dir needs a path\n' >&2; exit 2; }; OUTPUT_DIR="$2"; shift 2 ;;
    --version) [ $# -ge 2 ] || { printf 'package-engine: --version needs a value\n' >&2; exit 2; }; VERSION="$2"; shift 2 ;;
    *) printf 'package-engine: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$VERSION" in ''|*[!A-Za-z0-9._+-]*) printf 'package-engine: unsafe version: %s\n' "$VERSION" >&2; exit 2 ;; esac
command -v go >/dev/null 2>&1 || { printf 'package-engine: Go is required\n' >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { printf 'package-engine: sha256sum is required\n' >&2; exit 2; }

goos="$(go env GOOS)"; goarch="$(go env GOARCH)"
[ "$goos" = linux ] || { printf 'package-engine: release engine must target Linux, got %s\n' "$goos" >&2; exit 2; }
install -d "$OUTPUT_DIR"
artifact="$OUTPUT_DIR/yard-$VERSION-$goos-$goarch"
YARD_BUILD_VERSION="$VERSION" "$SCRIPT_DIR/build-engine.sh" --force --output "$artifact"
(
  cd "$OUTPUT_DIR"
  sha256sum "$(basename "$artifact")" > "$(basename "$artifact").sha256"
)
printf '{"schemaVersion":1,"version":"%s","os":"%s","arch":"%s","rpc":{"min":1,"max":1},"projectStateSchema":1,"credentialSchema":1}\n' \
  "$VERSION" "$goos" "$goarch" > "$artifact.manifest.json"
chmod 0644 "$artifact.sha256" "$artifact.manifest.json"
printf '%s\n' "$artifact"
