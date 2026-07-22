#!/usr/bin/env bash
# Install a packaged candidate through the operator-facing release flow and exercise it from an
# isolated home. A failing Go stub proves that install and bootstrap execution do not compile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d /tmp/subyard-installed-cli.XXXXXX)"
cleanup() {
  case "$TMP" in /tmp/subyard-installed-cli.*) find "$TMP" -depth -delete ;; esac
}
trap cleanup EXIT

release="$TMP/release"
artifact="$("$ROOT/scripts/package-engine.sh" --output-dir "$release" --version 0.1.0-dev)"
bundle="${artifact/\/yard-/\/subyard-}.tar.gz"
bundle_before="$(sha256sum "$bundle" | cut -d' ' -f1)"

install -d "$TMP/home" "$TMP/config" "$TMP/data" "$TMP/bin" "$TMP/no-go"
cat > "$TMP/no-go/go" <<EOF
#!/bin/sh
printf 'Go was invoked by the installed CLI acceptance test\n' > '$TMP/go-invoked'
exit 99
EOF
chmod 0700 "$TMP/no-go/go"

export HOME="$TMP/home"
export SUBYARD_OPERATOR_HOME="$TMP/home"
export SUBYARD_CONFIG_HOME="$TMP/config"
export SUBYARD_HOME="$TMP/data"
export YARD_BIN_DIR="$TMP/bin"
export YARD_SHELL_RC="$TMP/bashrc"
export ASSUME_YES=1
export YARD_RELEASE_BASE_URL="file://$release"
export YARD_RELEASE_VERSION=0.1.0-dev
export PATH="$TMP/no-go:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

"$ROOT/scripts/install-cli.sh" >/dev/null
[ -L "$YARD_BIN_DIR/yard" ] && [ -L "$YARD_BIN_DIR/sy" ] \
  || { printf 'installed-cli: installer did not create both launchers\n' >&2; exit 1; }
[ "$(readlink -f "$YARD_BIN_DIR/yard")" = "$(readlink -f "$SUBYARD_HOME/runtime/current/bin/yard")" ] \
  || { printf 'installed-cli: yard launcher target is incorrect\n' >&2; exit 1; }
[ "$(readlink -f "$YARD_BIN_DIR/sy")" = "$(readlink -f "$SUBYARD_HOME/runtime/current/bin/yard")" ] \
  || { printf 'installed-cli: sy launcher target is incorrect\n' >&2; exit 1; }

[ "$("$YARD_BIN_DIR/yard" --version)" = 'yard 0.1.0-dev' ] \
  || { printf 'installed-cli: installed engine version check failed\n' >&2; exit 1; }
"$YARD_BIN_DIR/yard" --command-manifest | grep -Fq 'start||@lifecycle'
"$YARD_BIN_DIR/yard" _migrate check >/dev/null
[ ! -e "$TMP/go-invoked" ] \
  || { printf 'installed-cli: bootstrap unexpectedly invoked Go\n' >&2; exit 1; }
[ "$(sha256sum "$bundle" | cut -d' ' -f1)" = "$bundle_before" ] \
  || { printf 'installed-cli: installer modified the release bundle\n' >&2; exit 1; }
[ -x "$SUBYARD_HOME/runtime/current/bin/yard-engine" ] \
  || { printf 'installed-cli: verified engine was not installed in the runtime directory\n' >&2; exit 1; }
[ -x "$SUBYARD_HOME/runtime/current/scripts/install-runtime-release.sh" ] \
  && [ -r "$SUBYARD_HOME/runtime/current/config/commands.registry" ] \
  || { printf 'installed-cli: release runtime is not self-contained\n' >&2; exit 1; }
grep -Fq 'Subyard CLI login PATH' "$HOME/.profile" \
  || { printf 'installed-cli: login-shell PATH was not configured\n' >&2; exit 1; }
HOME="$HOME" bash -lc 'command -v yard >/dev/null' \
  || { printf 'installed-cli: login shell cannot resolve yard\n' >&2; exit 1; }

printf 'ok: release candidate installed and ran through the stable launcher without Go\n'
