#!/usr/bin/env bash
# cache.sh — remote owner probe cache helpers.

[ -n "${SUBYARD_CACHE_SOURCED:-}" ] && return 0
SUBYARD_CACHE_SOURCED=1

remote_cache_path() { printf '%s/remote-%s.cache\n' "$SUBYARD_HOME" "$1"; }

remote_info_keep_cached_projects() {
  local json="$1" cache="$2" projects cached
  projects="$(json_num "$json" projects)"
  if [ -n "$projects" ] || [ ! -f "$cache" ]; then printf '%s\n' "$json"; return 0; fi
  cached="$(sed -n '2p' "$cache" 2>/dev/null)"
  projects="$(json_num "$cached" projects)"
  if [ -z "$projects" ]; then printf '%s\n' "$json"; return 0; fi
  case "$json" in
    *'"projects":null'*) printf '%s\n' "${json/\"projects\":null/\"projects\":$projects}" ;;
    *) printf '%s\n' "$json" ;;
  esac
}
