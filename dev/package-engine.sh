#!/usr/bin/env bash
# Build versioned Linux release artifacts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$REPO/.build/release"
VERSION="${YARD_BUILD_VERSION:-0.1.0-dev}"
TARGET_ARCH="$(go env GOARCH 2>/dev/null || true)"

while [ $# -gt 0 ]; do
  case "$1" in
    --output-dir) [ $# -ge 2 ] || { printf 'package-engine: --output-dir needs a path\n' >&2; exit 2; }; OUTPUT_DIR="$2"; shift 2 ;;
    --version) [ $# -ge 2 ] || { printf 'package-engine: --version needs a value\n' >&2; exit 2; }; VERSION="$2"; shift 2 ;;
    --arch) [ $# -ge 2 ] || { printf 'package-engine: --arch needs amd64 or arm64\n' >&2; exit 2; }; TARGET_ARCH="$2"; shift 2 ;;
    *) printf 'package-engine: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$VERSION" in ''|*[!A-Za-z0-9._+-]*) printf 'package-engine: unsafe version: %s\n' "$VERSION" >&2; exit 2 ;; esac
command -v go >/dev/null 2>&1 || { printf 'package-engine: Go is required\n' >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { printf 'package-engine: sha256sum is required\n' >&2; exit 2; }
case "$TARGET_ARCH" in amd64 | arm64) ;; *) printf 'package-engine: unsupported architecture: %s\n' "$TARGET_ARCH" >&2; exit 2 ;; esac

goos=linux; goarch="$TARGET_ARCH"
install -d "$OUTPUT_DIR"
install -m 0755 "$REPO/dev/bootstrap-runtime.sh" "$OUTPUT_DIR/subyard-install.sh"
install -m 0755 "$REPO/scripts/install-runtime-release.sh" \
  "$OUTPUT_DIR/subyard-install-runtime-release.sh"
( cd "$OUTPUT_DIR" && sha256sum subyard-install-runtime-release.sh \
    > subyard-install-runtime-release.sh.sha256 )
artifact="$OUTPUT_DIR/yard-$VERSION-$goos-$goarch"
GOOS="$goos" GOARCH="$goarch" YARD_BUILD_VERSION="$VERSION" \
  "$SCRIPT_DIR/build-engine.sh" --force --output "$artifact"
(
  cd "$OUTPUT_DIR"
  sha256sum "$(basename "$artifact")" > "$(basename "$artifact").sha256"
)
printf '{"schemaVersion":1,"version":"%s","os":"%s","arch":"%s","rpc":{"min":1,"max":1},"projectStateSchema":1,"credentialSchema":1}\n' \
  "$VERSION" "$goos" "$goarch" > "$artifact.manifest.json"
artifact_hash="$(cut -d' ' -f1 "$artifact.sha256")"
revision="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || printf unknown)"
generated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"schemaVersion":1,"artifact":"%s","sha256":"%s","version":"%s","sourceRepository":"github.com/Dmitry-Borodin/Subyard","sourceRevision":"%s","generatedAt":"%s"}\n' \
  "$(basename "$artifact")" "$artifact_hash" "$VERSION" "$revision" "$generated" \
  > "$artifact.provenance.json"
chmod 0644 "$artifact.sha256" "$artifact.manifest.json" "$artifact.provenance.json"

# Publish a self-contained runtime. The installed launcher resolves this directory as its
# repository root, so production never reads scripts/config from a source checkout.
bundle="$OUTPUT_DIR/subyard-$VERSION-$goos-$goarch.tar.gz"
bundle_stage="$(mktemp -d "$OUTPUT_DIR/.runtime-bundle.XXXXXX")"
cleanup_bundle() { rm -rf -- "$bundle_stage"; }
trap cleanup_bundle EXIT
install -d "$bundle_stage/bin"
install -m 0755 "$artifact" "$bundle_stage/bin/yard-engine"
install -m 0755 "$REPO/bin/yard" "$bundle_stage/bin/yard"
cp -a "$REPO/scripts" "$REPO/config" "$REPO/completions" "$bundle_stage/"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$bundle_stage" -cf - . \
  | gzip -n > "$bundle"
chmod 0644 "$bundle"
(
  cd "$OUTPUT_DIR"
  sha256sum "$(basename "$bundle")" > "$(basename "$bundle").sha256"
)
printf '{"schemaVersion":1,"kind":"runtime","version":"%s","os":"%s","arch":"%s","rpc":{"min":1,"max":1},"projectStateSchema":1,"credentialSchema":1}\n' \
  "$VERSION" "$goos" "$goarch" > "$bundle.manifest.json"
bundle_hash="$(cut -d' ' -f1 "$bundle.sha256")"
printf '{"schemaVersion":1,"artifact":"%s","sha256":"%s","version":"%s","sourceRepository":"github.com/Dmitry-Borodin/Subyard","sourceRevision":"%s","generatedAt":"%s"}\n' \
  "$(basename "$bundle")" "$bundle_hash" "$VERSION" "$revision" "$generated" \
  > "$bundle.provenance.json"
chmod 0644 "$bundle.sha256" "$bundle.manifest.json" "$bundle.provenance.json"
cleanup_bundle
trap - EXIT
printf '%s\n' "$artifact"
