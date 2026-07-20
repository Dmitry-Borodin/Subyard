#!/usr/bin/env bash
# install-power-reconciler.sh — install/remove the root-owned host boot power reconciler.
# Internal lifecycle helper; `yard init` installs it and the last `yard teardown` removes it.
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

LIBEXEC_DIR="${SUBYARD_POWER_LIBEXEC_DIR:-/usr/local/libexec/subyard}"
RECONCILER_PATH="${SUBYARD_POWER_RECONCILER_PATH:-$LIBEXEC_DIR/yard-boot-reconcile}"
POWER_LIB_PATH="${SUBYARD_POWER_LIB_PATH:-$LIBEXEC_DIR/lib-power.sh}"
UNIT_PATH="${SUBYARD_POWER_UNIT_PATH:-/etc/systemd/system/subyard-power-reconcile.service}"
UNIT_NAME="$(basename "$UNIT_PATH")"
TEMPLATE="$SCRIPT_DIR/../config/systemd/subyard-power-reconcile.service.in"

action=install
for arg in "$@"; do
  case "$arg" in
    --remove-if-unused) action=remove-if-unused ;;
    -y|--yes) ;;
    -*) die "unknown option '$arg'" ;;
  esac
done

if [ "$action" = install ]; then
  announce "Subyard — install guarded yard boot reconciliation" \
    "Install a root-owned systemd oneshot that restores only yards with desired=running after Incus/network guards are ready." \
    "Keep Incus boot.autostart=false; validate NetworkManager and host default routes before and after every yard start."
else
  announce "Subyard — remove unused yard boot reconciliation" \
    "Disable and remove the host boot reconciler only when no managed local yard remains."
fi
proceed_or_die
require_root "installing a host systemd unit and root-owned reconciler needs root"

if [ "$action" = remove-if-unused ]; then
  if command -v incus >/dev/null 2>&1; then
    if ! incus info >/dev/null 2>&1; then
      warn "Incus is unreachable — retaining the boot reconciler fail-closed"
      exit 0
    fi
    if power_any_managed_instance; then
      ok "managed yards remain — keeping $UNIT_NAME"
      exit 0
    fi
  fi
  systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  rm -f "$UNIT_PATH" "$RECONCILER_PATH" "$POWER_LIB_PATH"
  rmdir "$LIBEXEC_DIR" 2>/dev/null || true
  systemctl daemon-reload
  ok "removed unused $UNIT_NAME"
  exit 0
fi

[ -r "$TEMPLATE" ] || die "systemd template missing: $TEMPLATE"
install -d -o root -g root -m 0755 "$LIBEXEC_DIR" "$(dirname "$UNIT_PATH")"
install -o root -g root -m 0755 "$SCRIPT_DIR/yard-boot-reconcile.sh" "$RECONCILER_PATH"
install -o root -g root -m 0644 "$SCRIPT_DIR/lib-power.sh" "$POWER_LIB_PATH"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed "s|@SUBYARD_POWER_RECONCILER@|$RECONCILER_PATH|g" "$TEMPLATE" > "$tmp"
if [ ! -f "$UNIT_PATH" ] || ! cmp -s "$tmp" "$UNIT_PATH"; then
  install -o root -g root -m 0644 "$tmp" "$UNIT_PATH"
  ok "installed $UNIT_PATH"
else
  ok "$UNIT_NAME already current"
fi
systemctl daemon-reload
systemctl enable "$UNIT_NAME" >/dev/null
ok "$UNIT_NAME enabled (it runs on boot; not started during setup)"
