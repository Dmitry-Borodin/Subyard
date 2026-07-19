#!/usr/bin/env bash
# yard-yards.sh — list every yard on this host: the default yard plus each named yard in
# the registry (private/yards/*.env and ~/.config/subyard/yards/*.env).
# Columns: NAME  TYPE  INSTANCE  STATE  SSH  PROJECTS  SIZE
#   TYPE      local or remote
#   STATE     local: RUNNING/STOPPED from incus, '-' when incus/the instance is absent; remote:
#             from an `_info` probe of the owner host, else the cached state + 'seen <age> ago',
#             else '?' (never dies, never blocks longer than the 2s probe timeout)
#   SSH       local: the yard's host loopback port; remote: the 'yard-<name>' ProxyJump alias
#   PROJECTS  count of machine-local project records (local) / live yard-side remote metadata
#   SIZE      the yard's last cached size (yard status refreshes it), or '-'
# Read-only; operator-owned; no root. Works with or without incus on PATH; remote probes need ssh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

for a in "$@"; do case "$a" in -y | --yes) ;; -*) die "unknown option '$a'" ;; *) die "yards takes no arguments" ;; esac; done

# Resolve one yard's derived context in a subshell (no incus, never dies): source its env file
# + name derivations, then the config defaults, and print a tab record. Unset the per-yard keys
# first so an inherited context (this process may run under -Y) can't leak into another yard's row.
yard_record() {
  local name="$1"
  (
    unset INSTANCE_NAME INCUS_PROJECT SSH_HOST SSH_PORT SRV_VOLUME \
          RESTRICTED_DISK_PATHS SUBYARD_STATE_DIR YARD_TYPE YARD_NAME \
          REMOTE_DEST REMOTE_YARD
    local declared_port=''
    if [ "$name" != default ]; then
      local f
      f="$(yard_env_file "$name")" || return 0
      # shellcheck disable=SC1090
      . "$f"
      _yard_apply_derivations "$name"
      declared_port="${SSH_PORT:-}"   # a local named yard must declare it; '' => show '-'
    fi
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/../config/incus.project.env"
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/../config/subyard.env"
    [ "$name" = default ] && declared_port="${SSH_PORT:-}"
    local type=local; [ "${YARD_TYPE:-local}" = remote ] && type=remote
    local statedir="${SUBYARD_STATE_DIR:-$SUBYARD_CONFIG_HOME/projects}"
    # Per-yard size cache (matches yard-ctl.sh: default → space.cache, named → space-<name>.cache).
    local cache="$SUBYARD_HOME/space.cache"
    [ "$name" != default ] && cache="$SUBYARD_HOME/space-$name.cache"
    # Emit '-' (never an empty field): tab is an IFS whitespace char, so an empty middle field
    # would collapse and shift every column. The trailing REMOTE_DEST/REMOTE_YARD drive the
    # remote probe below; '-' means "not set" (a local yard, or a remote targeting the owner's
    # DEFAULT yard).
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$type" "$INSTANCE_NAME" "$INCUS_PROJECT" "${declared_port:--}" "$statedir" "$cache" \
      "${REMOTE_DEST:--}" "${REMOTE_YARD:--}"
  )
}

# STATE from incus for a local yard; '-' if incus is missing or the instance is unknown.
yard_state() {
  local inst="$1" proj="$2" s=''
  command -v incus >/dev/null 2>&1 || { printf '%s' '-'; return 0; }
  s="$(incus list "$inst" --project "$proj" -f csv -c s 2>/dev/null | head -n1)" || s=''
  printf '%s' "${s:--}"
}

cache_size() {
  local cache="$1" fig=''
  [ -f "$cache" ] || { printf '%s' '-'; return 0; }
  read -r fig _ < "$cache" 2>/dev/null || true
  printf '%s' "${fig:--}"
}

# --- remote-yard state -------------------------------------------------------
# STATE/PROJECTS for a remote row come from the owner host's `yard _info` over ssh (2s timeout).
# All probes run in PARALLEL below and are awaited together, so N unreachable hosts cost ~2s total,
# not 2s each. The last good answer is cached in $SUBYARD_HOME/remote-<name>.cache (line 1 = epoch,
# line 2 = _info JSON); an unreachable host shows that cached state with 'seen <age> ago', else '?'.
# json_str/json_num, age_human and count_json_files live in lib.sh.

remote_probe() { # <dest> <ryard> -> _info JSON on stdout (empty on failure)
  local dest="$1" ryard="$2" rc='yard _info'
  [ -n "$ryard" ] && rc="yard -Y $(printf '%q' "$ryard") _info"
  ssh -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new \
      "$dest" -- bash -lc "$(printf '%q' "$rc")" 2>/dev/null
}

# Pass 1: gather every yard's record and, for reachable-only speed, fire off all remote probes
# in the background (results land in per-yard temp files); then wait for them together.
probe_tmp="$(mktemp -d "${TMPDIR:-/tmp}/yard-yards.XXXXXX")" || probe_tmp=''
[ -n "$probe_tmp" ] && trap 'rm -rf "$probe_tmp"' EXIT
names=(); records=()
while IFS= read -r name; do
  [ -n "$name" ] || continue
  rec="$(yard_record "$name")" || continue
  [ -n "$rec" ] || continue
  names+=("$name"); records+=("$rec")
  IFS=$'\t' read -r _n rtype _i _p _port _sd _c rdest rry <<EOF
$rec
EOF
  if [ "$rtype" = remote ] && [ "$rdest" != '-' ] && [ -n "$probe_tmp" ]; then
    ry=''; [ "$rry" != '-' ] && ry="$rry"
    remote_probe "$rdest" "$ry" > "$probe_tmp/$name.json" 2>/dev/null &
  fi
done < <(yard_registry_names)
wait

# Pass 2: print. Local rows probe incus inline (fast/local); remote rows read their probe file
# (or the last-seen cache). The 'seen <age> ago' note trails the row so columns never shift.
printf '%s%-14s %-6s %-16s %-9s %-7s %-8s %s%s\n' \
  "$C_HEAD" NAME TYPE INSTANCE STATE SSH PROJECTS SIZE "$C_OFF"

now="$(date +%s)"
for i in "${!names[@]}"; do
  name="${names[$i]}"
  IFS=$'\t' read -r rname rtype rinst rproj rport rstatedir rcache rdest rry <<EOF
${records[$i]}
EOF
  if [ "$rtype" != remote ]; then
    rstate="$(yard_state "$rinst" "$rproj")"
    rprojects="$(count_json_files "$rstatedir")"
    rsize="$(cache_size "$rcache")"
    printf '%-14s %-6s %-16s %-9s %-7s %-8s %s\n' \
      "$rname" "$rtype" "$rinst" "$rstate" "${rport:--}" "$rprojects" "$rsize"
    continue
  fi
  # Remote row. Reset per-iteration: these vars are script-global (not function-local), so a
  # prior local row's rstate='-'/rprojects=0 must not leak in through a ':=' default here.
  remcache="$(remote_cache_path "$name")"
  json=''; [ -n "$probe_tmp" ] && [ -f "$probe_tmp/$name.json" ] && json="$(cat "$probe_tmp/$name.json")"
  rstate=''; rprojects=''; marker=''; rsize='-'
  case "$json" in
    '{'*'}')   # reachable — refresh state and retain last-good projects if live metadata failed
      json="$(remote_info_keep_cached_projects "$json" "$remcache")"
      rstate="$(json_str "$json" state)"; rprojects="$(json_num "$json" projects)"
      install -d -m 700 "$SUBYARD_HOME" 2>/dev/null || true
      { printf '%s\n' "$now"; printf '%s\n' "$json"; } > "$remcache.tmp" 2>/dev/null \
        && mv -f "$remcache.tmp" "$remcache" 2>/dev/null || true
      ;;
    *)         # unreachable — fall back to the cache (leave rstate/rprojects empty otherwise)
      if [ -f "$remcache" ]; then
        epoch="$(sed -n 1p "$remcache" 2>/dev/null)"; cjson="$(sed -n 2p "$remcache" 2>/dev/null)"
        rstate="$(json_str "$cjson" state)"; rprojects="$(json_num "$cjson" projects)"
        case "$epoch" in ''|*[!0-9]*) ;; *) marker="  (seen $(age_human $((now - epoch))) ago)" ;; esac
      fi
      ;;
  esac
  printf '%-14s %-6s %-16s %-9s %-7s %-8s %s%s\n' \
    "$rname" remote "$rinst" "${rstate:-?}" "yard-$name" "${rprojects:--}" "$rsize" "$marker"
done
