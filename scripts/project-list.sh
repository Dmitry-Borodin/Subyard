#!/usr/bin/env bash
# project-list.sh — Phase 7b (slice): list projects currently in the yard.
# Reads machine-local state ($SUBYARD_CONFIG_HOME/projects/*.json) — works even
# when the yard is down. If incus is reachable, also reports whether each yard
# copy is present. Read-only; operator-owned; no root.
# Config: config/incus.project.env + config/subyard.env + config/host.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

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
# Read all fields up front: one jq per project (not one per field) — @tsv keeps
# the four values on a single line. Project records have no tabs in these fields.
names=() modes=() hostPaths=() yardPaths=()
for id in "${ids[@]}"; do
  IFS=$'\t' read -r name mode hostPath yardPath \
    < <(jq -r '[.name,.mode,.hostPath,.yardPath]|@tsv' "$(state_file "$id")")
  names+=("$name"); modes+=("$mode"); hostPaths+=("$hostPath"); yardPaths+=("$yardPath")
done

# Presence in the yard: one `incus exec` for the whole list (not one per project) —
# feed the yard paths on stdin and get present/missing back, in order. The per-project
# round-trip was the bottleneck for `yard list`. Unknown ('?') when the yard is down.
present=()
if [ "$yard_up" = 1 ]; then
  mapfile -t present < <(
    printf '%s\n' "${yardPaths[@]}" \
      | incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- sh -c '
          while IFS= read -r p; do
            { [ -n "$p" ] && [ -d "$p" ]; } && echo present || echo missing
          done' 2>/dev/null
  )
fi

printf '%-22s %-6s %-8s %s\n' NAME MODE YARD "HOST PATH"
for i in "${!ids[@]}"; do
  if [ "$yard_up" = 1 ]; then yard="${present[$i]:-?}"; else yard='?'; fi
  printf '%-22s %-6s %-8s %s\n' "${names[$i]}" "${modes[$i]}" "$yard" "${hostPaths[$i]}"
done
