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
# the values on a single line. Project records have no tabs in these fields. `target`
# (the run tier: `yard` = L1, a profile name = L2) may be absent in old records — default yard.
names=() modes=() hostPaths=() yardPaths=() targets=()
for id in "${ids[@]}"; do
  IFS=$'\t' read -r name mode hostPath yardPath target \
    < <(jq -r '[.name,.mode,.hostPath,.yardPath,(.target // "yard")]|@tsv' "$(state_file "$id")")
  names+=("$name"); modes+=("$mode"); hostPaths+=("$hostPath"); yardPaths+=("$yardPath")
  targets+=("${target:-yard}")
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

# L2 box state: one `docker ps` for the whole list (not one per project). Map each
# project-env box's project id (label subyard.project) to its container state, so an L2
# project shows up/down/none below. L1 (target=yard) has no box — shown as '-'.
declare -A boxstate
if [ "$yard_up" = 1 ]; then
  while IFS=$'\t' read -r pid st; do
    [ -n "$pid" ] && boxstate["$pid"]="$st"
  done < <(
    incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- \
      docker ps -a --filter 'label=subyard.env=1' \
        --format '{{index .Labels "subyard.project"}}'$'\t''{{.State}}' 2>/dev/null
  )
fi

# box_for <index> — the BOX column for a project: '-' for L1 (no box; ASCII so the fixed-width
# column stays aligned); for L2 either up/down (mapped from the container state), 'none' when no
# box exists yet, or '?' when the yard is down so its state is unknown.
box_for() {
  local i="$1"; local tgt="${targets[$i]}"
  case "$tgt" in ''|yard) printf '%s' '-'; return ;; esac
  [ "$yard_up" = 1 ] || { printf '%s' '?'; return; }
  case "${boxstate[${ids[$i]}]:-}" in
    running) printf '%s' up ;;
    '')      printf '%s' none ;;
    *)       printf '%s' down ;;   # exited/created/paused/restarting
  esac
}

printf '%-22s %-6s %-10s %-8s %-5s %s\n' NAME MODE TARGET YARD BOX "HOST PATH"
for i in "${!ids[@]}"; do
  if [ "$yard_up" = 1 ]; then yard="${present[$i]:-?}"; else yard='?'; fi
  printf '%-22s %-6s %-10s %-8s %-5s %s\n' \
    "${names[$i]}" "${modes[$i]}" "${targets[$i]}" "$yard" "$(box_for "$i")" "${hostPaths[$i]}"
done
