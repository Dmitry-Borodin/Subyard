#!/usr/bin/env bash
# metadata.sh — yard-side project metadata discovery and owner registry reconciliation.

[ -n "${SUBYARD_STATE_METADATA_SOURCED:-}" ] && return 0
SUBYARD_STATE_METADATA_SOURCED=1

# --- yard-side meta ----------------------------------------------------------
# On sync/clone we drop /srv/workspaces/<id>/.subyard-meta.json next to src/ so any controller
# (a second laptop) can discover what the yard holds even without local state. Best-effort:
# a meta failure only WARNs, it never fails the sync/clone.

# yard_meta_json <id> <name> <mode> <target> — schema-1 meta; origin is this controller's host.
yard_meta_json() {
  jq -cn --argjson schema 1 --arg projectId "$1" --arg name "$2" --arg mode "$3" --arg target "$4" \
    --arg importedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg origin "$(hostname 2>/dev/null || uname -n 2>/dev/null || printf unknown)" \
    '{schema:$schema,projectId:$projectId,name:$name,mode:$mode,target:$target,importedAt:$importedAt,origin:$origin}'
}

# write_yard_meta <id> <name> <mode> <target> — write meta over the SAME transport the copy used:
# ssh when the alias is up (works for local and remote), else incus exec for a LOCAL yard.
# Always returns 0 — on any failure it warns and moves on (never breaks sync/clone).
write_yard_meta() {
  local id="$1" name="$2" mode="$3" target="$4" json dir dst
  dir="/srv/workspaces/$id"; dst="$dir/.subyard-meta.json"
  json="$(yard_meta_json "$id" "$name" "$mode" "$target" 2>/dev/null)" \
    || { warn "could not build yard meta for '$name' (skipped; non-fatal)"; return 0; }
  # Attempt the ssh write directly (BatchMode + short timeout is its own reachability probe) —
  # saves a round-trip vs probe-then-write. On failure fall back to incus for a LOCAL yard, with
  # --user/--group so the meta is dev-owned in the dev-owned tree (not root-owned via `sh -c`).
  if printf '%s\n' "$json" | ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_HOST:-yard}" "cat > '$dst'" 2>/dev/null; then
    return 0
  fi
  if ! yard_is_remote && command -v incus >/dev/null 2>&1; then
    printf '%s\n' "$json" \
      | incus exec "${INSTANCE_NAME:-yard}" --project "${INCUS_PROJECT:-subyard}" \
          --user "${DEV_UID:-1000}" --group "${DEV_UID:-1000}" -- \
          sh -c "cat > '$dst'" 2>/dev/null \
      && return 0
  fi
  warn "could not write yard meta for '$name' (non-fatal)"; return 0
}

# --- yard-side reconcile (list --live) ---------------------------------------
# `list --live`, and register-on-demand in remove/code, read the yard's meta files over the
# same transport. Non-fatal: an unreachable yard yields no rows, never a hang or a die.

# _yard_meta_stream <ssh_host> <remote:0|1> <instance> <project> — cat every meta in the yard
# (concatenated JSON objects) via ssh (remote, or local when the alias is up) else incus exec.
_yard_meta_stream() {
  local host="$1" remote="$2" inst="$3" proj="$4"
  local cmd='for f in /srv/workspaces/*/.subyard-meta.json; do [ -e "$f" ] || continue; cat "$f"; printf "\n"; done'
  if [ "$remote" = 1 ]; then
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" "$cmd" 2>/dev/null || true
  elif ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" true 2>/dev/null; then
    ssh "$host" "$cmd" 2>/dev/null || true
  elif command -v incus >/dev/null 2>&1; then
    incus exec "$inst" --project "$proj" -- sh -c "$cmd" 2>/dev/null || true
  fi
}

# _yard_meta_parse — stdin: concatenated meta JSON → `id\tname\tmode\ttarget` per object.
_yard_meta_parse() {
  jq -r 'select(type=="object") | [.projectId,(.name//""),(.mode//""),(.target//"")] | @tsv' 2>/dev/null || true
}

# yard_live_projects — meta rows (id\tname\tmode\ttarget) for the ACTIVE context's yard.
yard_live_projects() {
  local remote=0; yard_is_remote && remote=1
  _yard_meta_stream "${SSH_HOST:-yard}" "$remote" "${INSTANCE_NAME:-yard}" "${INCUS_PROJECT:-subyard}" \
    | _yard_meta_parse
}

# yard_live_project_count_local — strict owner-side count for `yard _info`. Unlike the
# best-effort list helpers above, this distinguishes an empty running yard (prints 0) from a
# failed/unparseable observation (returns non-zero and prints nothing), so remote controllers can
# retain a last-good count instead of caching a false zero. Project IDs are deduplicated because
# yard-side metadata, not controller-local state, is the source of truth for remote inventory.
yard_live_project_count_local() {
  local inst="${INSTANCE_NAME:-yard}" proj="${INCUS_PROJECT:-subyard}" raw ids
  local cmd='for f in /srv/workspaces/*/.subyard-meta.json; do [ -e "$f" ] || continue; cat "$f"; printf "\n"; done'
  command -v incus >/dev/null 2>&1 || return 1
  raw="$(incus exec "$inst" --project "$proj" -- sh -c "$cmd" 2>/dev/null)" || return 1
  ids="$(jq -r 'select(type == "object" and (.projectId | type == "string") and .projectId != "") | .projectId' \
    <<<"$raw" 2>/dev/null)" || return 1
  awk 'NF && !seen[$0]++ { n++ } END { print n + 0 }' <<<"$ids"
}
# yard_live_projects_for <name> — meta rows for ANY registry yard (used by the all-yards
# --live view). Derives the yard's ssh alias / instance / project through registry/config modules,
# honoring an explicit override in the env file.
yard_live_projects_for() {
  local y="$1" type host inst proj remote=0
  type="$(yard_env_peek "$y" YARD_TYPE)"; [ "$type" = remote ] && remote=1
  host="$(yard_env_peek "$y" SSH_HOST)"
  inst="$(yard_env_peek "$y" INSTANCE_NAME)"
  proj="$(yard_env_peek "$y" INCUS_PROJECT)"
  case "$y" in
    default) : "${host:=yard}"; : "${inst:=yard}"; : "${proj:=subyard}" ;;
    *)       : "${host:=yard-$y}"; : "${inst:=yard-$y}"; : "${proj:=subyard-$y}" ;;
  esac
  _yard_meta_stream "$host" "$remote" "$inst" "$proj" | _yard_meta_parse
}

# resolve_project_id_soft <arg> — like resolve_project_id but returns 1 instead of dying when
# nothing matches (so callers can try a yard-side reconcile before giving up).
resolve_project_id_soft() {
  state_engine resolve-local-soft "${1:-.}"
}

# maybe_reconcile <arg> — register-on-demand: under an EXPLICIT context, if <arg> is not in
# local state but the active yard holds a project of that id/name (per its meta), write a
# minimal local record (hostPath empty) so remove/code can act on it. Best-effort; the
# subsequent resolve_project_ctx then finds it. Does nothing without an explicit context.
maybe_reconcile() {
  [ -n "${SUBYARD_YARD_EXPLICIT:-}" ] || return 0
  local arg="${1:-.}" yid ynm ymode ytarget
  arg="$(project_arg_in_context "$arg")"
  resolve_project_id_soft "$arg" >/dev/null 2>&1 && return 0   # already known locally
  while IFS=$'\t' read -r yid ynm ymode ytarget; do
    [ -n "$yid" ] || continue
    state_yard_record_valid "$yid" "$ymode" "$ytarget" || continue
    if [ "$arg" = "$yid" ] || [ "${arg,,}" = "${ynm,,}" ]; then
      state_upsert_yard "$yid" "$ynm" "$ymode" "$ytarget" "${SSH_HOST:-yard}"
      warn "registered '$ynm' from the yard on demand (no host path recorded; export/sync from this machine need one — re-add with '$(yard_cmd_hint) sync <path>')"
      return 0
    fi
  done < <(yard_live_projects)
  return 0
}
