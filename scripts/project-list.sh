#!/usr/bin/env bash
# project-list.sh — Phase 7b (slice): list projects currently in the yard.
# Reads machine-local state ($SUBYARD_CONFIG_HOME/projects/*.json) — works even
# when the yard is down. If incus is reachable, also reports whether each yard
# copy is present. Read-only; operator-owned; no root.
#
# Multi-yard: with no explicit -Y/@ context and named yards defined, list every yard's projects
# with a YARD column, qualifying a NAME as `<yard>/<name>` when shared across yards (the form
# `yard code`/`remove`/… accept). An explicit context (or default-only) prints the single yard's
# table as before; default-only output is unchanged.
#
# --live (opt-in): also read the yard's own .subyard-meta.json files (over ssh for a remote yard,
# ssh/incus for a local one) to mark presence and surface projects that live only in the yard
# (synced from another machine, absent from local state) with a '(yard)' marker. Off by default
# so the common listing stays fast and its output byte-for-byte unchanged.
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

LIVE=0
for _a in "$@"; do case "$_a" in --live) LIVE=1 ;; esac; done

# list_single — the single-yard table for the loaded context's STATE_DIR (unchanged behavior
# without --live; probes incus for yard-copy presence and L2 box state when a LOCAL yard is
# up). With --live it reads the yard's meta to mark presence and append yard-only projects.
list_single() {
  mapfile -t ids < <(state_ids)

  # --live: the projects the yard itself reports (id\tname\tmode), keyed by id. Best-effort;
  # an unreachable yard yields none. Used to mark presence and surface yard-only projects.
  local -a live_rows=()
  local -A live_present=()
  local live_ok=0
  if [ "$LIVE" = 1 ]; then
    mapfile -t live_rows < <(yard_live_projects)
    # Did we actually reach the yard? Rows imply yes; otherwise probe once, so an unreachable
    # yard shows presence as '?' (unknown) rather than falsely marking everything 'missing'.
    { [ "${#live_rows[@]}" -gt 0 ] || yard_reachable; } && live_ok=1
    local _l _lid
    for _l in ${live_rows[@]+"${live_rows[@]}"}; do
      _lid="${_l%%$'\t'*}"; [ -n "$_lid" ] && live_present["$_lid"]=1
    done
  fi

  if [ "${#ids[@]}" -eq 0 ] && [ "${#live_rows[@]}" -eq 0 ]; then
    echo "No projects in the yard yet — add one with: ${PROG:-yard} sync <path> (or: bind <path>)"
    return 0
  fi

  # Probe the yard only if it is up — LOCAL yards only; a remote yard never touches incus and
  # gets its presence/box state from --live meta instead. Otherwise mark presence unknown.
  local yard_up=0
  if ! yard_is_remote && command -v incus >/dev/null 2>&1 \
     && [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ]; then
    yard_up=1
  fi
  # Read all fields up front: one jq per project (not one per field) — @tsv keeps
  # the values on a single line. Project records have no tabs in these fields. `target`
  # (the run tier: `yard` = L1, a profile name = L2) may be absent in old records — default yard.
  local -a names=() modes=() hostPaths=() yardPaths=() targets=()
  local id name mode hostPath yardPath target
  for id in "${ids[@]}"; do
    IFS=$'\t' read -r name mode hostPath yardPath target \
      < <(jq -r '[.name,.mode,.hostPath,.yardPath,(.target // "yard")]|@tsv' "$(state_file "$id")")
    names+=("$name"); modes+=("$mode"); hostPaths+=("$hostPath"); yardPaths+=("$yardPath")
    targets+=("${target:-yard}")
  done

  # Presence in the yard: one `incus exec` for the whole list (not one per project) —
  # feed the yard paths on stdin and get present/missing back, in order. The per-project
  # round-trip was the bottleneck for `yard list`. Unknown ('?') when the yard is down.
  local -a present=()
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
  local -A boxstate=()
  local pid st
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
  local i yard
  for i in ${ids[@]+"${!ids[@]}"}; do
    # --live: presence comes from the yard's own meta (present/missing). Else the incus probe
    # when the yard is up, else unknown ('?').
    if [ "$LIVE" = 1 ] && [ "$live_ok" = 1 ]; then
      [ -n "${live_present[${ids[$i]}]:-}" ] && yard=present || yard=missing
    elif [ "$yard_up" = 1 ]; then yard="${present[$i]:-?}"; else yard='?'; fi
    printf '%-22s %-6s %-10s %-8s %-5s %s\n' \
      "${names[$i]}" "${modes[$i]}" "${targets[$i]}" "$yard" "$(box_for "$i")" "${hostPaths[$i]}"
  done

  # --live: append projects present in the yard but absent from local state, marked '(yard)'.
  # These reconcile on demand for `yard remove`/`yard code` (register-on-demand from the meta).
  if [ "$LIVE" = 1 ] && [ "${#live_rows[@]}" -gt 0 ]; then
    local -A haveid=(); local _row lid lnm lmd
    for i in ${ids[@]+"${ids[@]}"}; do haveid["$i"]=1; done
    for _row in "${live_rows[@]}"; do
      IFS=$'\t' read -r lid lnm lmd <<<"$_row"
      [ -n "$lid" ] || continue
      [ -n "${haveid[$lid]:-}" ] && continue
      printf '%-22s %-6s %-10s %-8s %-5s %s\n' "$lnm" "$lmd" - present - '(yard)'
    done
  fi
}

# --- mode: single (explicit/named context, or default-only) vs multi (all yards) ----
mapfile -t yards < <(yard_registry_names)
explicit_ctx=0
{ [ -n "${YARD_NAME:-}" ] || [ -n "${SUBYARD_YARD_EXPLICIT:-}" ]; } && explicit_ctx=1
if [ "$explicit_ctx" = 1 ] || [ "${#yards[@]}" -le 1 ]; then
  # A default-only, non-explicit run prints the original table byte-for-byte (no header line).
  [ "$explicit_ctx" = 1 ] && printf 'Yard: %s\n' "${YARD_NAME:-default}"
  list_single
  exit 0
fi

# --- multi-yard overview: aggregate every registry yard's state (host-side only) ----
# Deliberately incus-free: probing each yard's instance/docker would need every yard running and
# is costly; this cross-yard view stays a fast, always-available roll-up of machine-local state.
rows=()
declare -A yards_per_name=()   # lowercased name -> space-joined distinct yards holding it
for y in "${yards[@]}"; do
  d="$(state_dir_for_yard "$y")"
  [ -d "$d" ] || continue
  for f in "$d"/*.json; do
    [ -e "$f" ] || continue
    IFS=$'\t' read -r nm md tg hp < <(jq -r '[.name,.mode,(.target // "yard"),.hostPath]|@tsv' "$f")
    id="$(basename "$f" .json)"
    rows+=("$y"$'\t'"$id"$'\t'"$nm"$'\t'"$md"$'\t'"${tg:-yard}"$'\t'"$hp")
    case " ${yards_per_name[${nm,,}]:-} " in
      *" $y "*) ;;                                                   # this yard already counted
      *) yards_per_name[${nm,,}]="${yards_per_name[${nm,,}]:-} $y" ;;
    esac
  done
done

# --live (opt-in): probe each yard for projects it holds that are absent from local state, so
# the all-yards view surfaces them too (marked '(yard)'). Off by default keeps this view fast
# and incus-free. An unreachable yard contributes nothing (best-effort).
extra=()
if [ "$LIVE" = 1 ]; then
  for y in "${yards[@]}"; do
    d="$(state_dir_for_yard "$y")"
    declare -A have=()
    if [ -d "$d" ]; then
      for f in "$d"/*.json; do [ -e "$f" ] && have["$(basename "$f" .json)"]=1; done
    fi
    while IFS=$'\t' read -r lid lnm lmd; do
      [ -n "$lid" ] || continue
      [ -n "${have[$lid]:-}" ] && continue
      extra+=("$y"$'\t'"$lnm"$'\t'"$lmd")
    done < <(yard_live_projects_for "$y")
    unset have
  done
fi

if [ "${#rows[@]}" -eq 0 ] && [ "${#extra[@]}" -eq 0 ]; then
  echo "No projects in any yard yet — add one with: ${PROG:-yard} sync <path> (or: bind <path>)"
  exit 0
fi

printf '%-12s %-24s %-6s %-10s %s\n' YARD NAME MODE TARGET "HOST PATH"
for r in ${rows[@]+"${rows[@]}"}; do
  IFS=$'\t' read -r y id nm md tg hp <<<"$r"
  disp="$nm"
  # Qualify the NAME as <yard>/<name> when the bare name is shared across 2+ yards, so the
  # printed NAME is unambiguous and copy-pastes straight into `yard code`/`remove`/….
  read -ra _yl <<<"${yards_per_name[${nm,,}]:-}"
  [ "${#_yl[@]}" -gt 1 ] && disp="$y/$nm"
  printf '%-12s %-24s %-6s %-10s %s\n' "$y" "$disp" "$md" "$tg" "$hp"
done
# Yard-only projects (present in the yard, no local record).
for r in ${extra[@]+"${extra[@]}"}; do
  IFS=$'\t' read -r y lnm lmd <<<"$r"
  printf '%-12s %-24s %-6s %-10s %s\n' "$y" "$lnm" "$lmd" - '(yard)'
done
