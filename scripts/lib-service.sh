#!/usr/bin/env bash
# Shared physical helpers for profile resource handlers.

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
PROJ=(--project "$INCUS_PROJECT")
yexec() { incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- "$@"; }

svc_require_yard_running() {
  incus_preflight
  incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
    || die "instance '$INSTANCE_NAME' missing — run '$(yard_cmd_hint) init' first"
  [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
    || die "yard is not running — start it: $(yard_cmd_hint) start"
}
