#!/usr/bin/env bash
# project-list.sh — Phase 7b (slice): list projects currently in the yard.
# Reads machine-local state ($SUBYARD_CONFIG_HOME/projects/*.json) — works even
# when the yard is down. If incus is reachable, also reports whether each yard
# copy is present. Read-only; operator-owned; no root.
# Config: config/incus.project.env + config/subyard.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

for cfg in incus.project.env subyard.env; do
  f="$SCRIPT_DIR/../config/$cfg"
  # shellcheck disable=SC1090
  [ -r "$f" ] && . "$f"
done
INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
PROJ=(--project "$INCUS_PROJECT")

mapfile -t ids < <(state_ids)
if [ "${#ids[@]}" -eq 0 ]; then
  echo "No projects in the yard yet — add one with: ${PROG:-yard} sync <path> (or: bind <path>)"
  exit 0
fi

# Probe the yard only if it is up; otherwise mark presence unknown.
yard_up=0
if command -v incus >/dev/null 2>&1 \
   && [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ]; then
  yard_up=1
fi
in_yard() { # <yardPath> → present|missing|?
  [ "$yard_up" = 1 ] || { printf '?'; return; }
  if incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- test -d "$1" 2>/dev/null; then
    printf 'present'
  else
    printf 'missing'
  fi
}

printf '%-22s %-6s %-8s %s\n' NAME MODE YARD "HOST PATH"
for id in "${ids[@]}"; do
  name="$(state_get "$id" name)"
  mode="$(state_get "$id" mode)"
  hostPath="$(state_get "$id" hostPath)"
  yardPath="$(state_get "$id" yardPath)"
  printf '%-22s %-6s %-8s %s\n' "$name" "$mode" "$(in_yard "$yardPath")" "$hostPath"
done
