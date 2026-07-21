#!/usr/bin/env bash
# test-vms.sh — owner/yard entrypoint for the disposable nested VM lab.
# On an owner host it enters the L1 yard; inside the yard it calls the installed
# inner worker directly. The worker never receives the L0 Incus socket.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# shellcheck source=scripts/lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"

WORKER=/usr/local/libexec/subyard/test-vms-inner
action="${1:-}"

# Source checkouts are commonly opened from inside the yard. The installed
# worker is an unambiguous marker; do not infer this boundary merely from LXC,
# because an owner host can itself be nested.
if [ -x "$WORKER" ]; then
  exec "$WORKER" "$@"
fi

[ "${NESTED_E2E_VMS:-0}" = 1 ] \
  || die "nested E2E VMs are disabled for this yard (set NESTED_E2E_VMS=1, then run '$(yard_cmd_hint) init')"
[ "${INSTANCE_TYPE:-container}" = container ] \
  || die "nested E2E VMs currently require INSTANCE_TYPE=container"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
PROJ=(--project "$INCUS_PROJECT")
incus_preflight
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "yard instance '$INSTANCE_NAME' is missing"
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard '$INSTANCE_NAME' is stopped — start it first"
incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- test -x "$WORKER" \
  || die "nested VM worker is not installed — re-run '$(yard_cmd_hint) init'"

case "$action" in
  up)
    announce "Create the disposable nested VM lab in $INSTANCE_NAME" \
      "Create/start exactly two VMs inside the yard's own Incus daemon." \
      "Install a synthetic SSH identity with passwordless sudo inside those VMs." \
      "Apply CPU/RAM/count limits and automatic TTL cleanup." \
      "No L0 Incus socket, host mount or real credential is exposed to the VMs."
    proceed_or_die
    set -- "$@" --yes
    ;;
  down)
    announce "Delete the disposable nested VM lab in $INSTANCE_NAME" \
      "Delete the two marked test VMs, their inner Incus project and synthetic SSH identity." \
      "Refuse cleanup if the project contains any unexpected instance."
    proceed_or_die
    set -- "$@" --yes
    ;;
esac

mode=non-interactive
case "$action" in ssh) mode=interactive ;; esac
exec incus exec "$INSTANCE_NAME" "${PROJ[@]}" --mode="$mode" -- "$WORKER" "$@"
