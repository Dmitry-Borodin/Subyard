#!/usr/bin/env bash
# install-keys-auto-sync.sh — install the operator-owned persistent 6-hour credential sync timer.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Explicit control-plane module composition (config/context loads exactly once).
# shellcheck source=scripts/lib/runtime.sh
. "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=scripts/lib/env.sh
. "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/registry.sh
. "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=scripts/lib/context.sh
. "$SCRIPT_DIR/lib/context.sh"
# shellcheck source=scripts/lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=scripts/lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
subyard_context_load
# shellcheck source=scripts/lib/cache.sh
. "$SCRIPT_DIR/lib/cache.sh"
# shellcheck source=scripts/lib-power.sh
. "$SCRIPT_DIR/lib-power.sh"
# shellcheck source=scripts/lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"

REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
UNIT_DIR="${SUBYARD_KEYS_SYSTEMD_DIR:-$SUBYARD_OPERATOR_HOME/.config/systemd/user}"
SERVICE="$UNIT_DIR/subyard-keys-sync.service"
TIMER="$UNIT_DIR/subyard-keys-sync.timer"
SERVICE_TEMPLATE="$REPO/config/systemd/subyard-keys-sync.service.in"
TIMER_TEMPLATE="$REPO/config/systemd/subyard-keys-sync.timer.in"
YARD_BIN="$(readlink -f "$REPO/bin/yard")"
SKIP_ENABLE="${SUBYARD_KEYS_SYSTEMD_SKIP_ENABLE:-0}"

render_service() { sed "s|@YARD_BIN@|$YARD_BIN|g" "$SERVICE_TEMPLATE"; }

units_current() {
  [ -r "$SERVICE" ] && [ -r "$TIMER" ] \
    && cmp -s <(render_service) "$SERVICE" && cmp -s "$TIMER_TEMPLATE" "$TIMER"
}

timer_enabled() {
  [ "$SKIP_ENABLE" = 1 ] && return 0
  systemctl --user is-enabled --quiet subyard-keys-sync.timer 2>/dev/null || return 1
  command -v loginctl >/dev/null 2>&1 || return 1
  [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)" = yes ] || return 1
}

case "${1:-}" in
  --check) units_current && timer_enabled; exit ;;
  -h|--help)
    cat <<EOF
Usage: install-keys-auto-sync.sh [--check] [-y]

Install and enable a persistent operator-owned timer that runs encrypted credential sync every 6 hours.
EOF
    exit 0 ;;
esac

if units_current && timer_enabled; then
  ok "encrypted credential auto-sync timer already installed"
  exit 0
fi

announce "Enable automatic encrypted credential synchronization" \
  "Install user units under $UNIT_DIR." \
  "Attempt synchronization every 6 hours with a persistent boot catch-up and randomized delay." \
  "Enable systemd lingering for $(id -un), if needed, so the timer continues after logout." \
  "Only peers approved by 'yard keys trust' participate; no recipient is enrolled automatically."
proceed_or_die

install -d -m 700 "$UNIT_DIR"
render_service > "$SERVICE.tmp"; chmod 0644 "$SERVICE.tmp"; mv -f "$SERVICE.tmp" "$SERVICE"
install -m 0644 "$TIMER_TEMPLATE" "$TIMER.tmp"; mv -f "$TIMER.tmp" "$TIMER"

if [ "$SKIP_ENABLE" = 1 ]; then
  ok "installed credential auto-sync unit files (enable skipped by test override)"
  exit 0
fi
command -v systemctl >/dev/null 2>&1 || die "systemctl is required for the automatic credential sync timer"
command -v loginctl >/dev/null 2>&1 || die "loginctl is required to keep automatic credential sync running after logout"
linger="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)"
if [ "$linger" != yes ]; then
  if [ "$(id -u)" -eq 0 ]; then
    loginctl enable-linger "$(id -un)" || die "could not enable systemd lingering"
  elif command -v sudo >/dev/null 2>&1; then
    sudo loginctl enable-linger "$(id -un)" || die "could not enable systemd lingering"
  else
    die "systemd lingering is disabled and sudo is unavailable; the 24-hour sync bound cannot be installed"
  fi
fi
systemctl --user daemon-reload || die "could not reload the user systemd manager"
systemctl --user enable --now subyard-keys-sync.timer \
  || die "could not enable subyard-keys-sync.timer"
ok "enabled subyard-keys-sync.timer (6-hour interval, persistent catch-up)"
