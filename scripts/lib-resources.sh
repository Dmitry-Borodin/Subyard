#!/usr/bin/env bash
# lib-resources.sh — the profile shared-resource REGISTRY (pure bash, no deps).
#
# A profile exposes long-lived in-yard services (the android profile: an emulator; the openclaw
# profile: a staging gateway + a QA bot-broker). Each is declared by a DESCRIPTOR file
#   config/profiles/<profile>/resources/<name>.res
# a sourced KEY=VALUE file that tells the yard core how to DISCOVER, DISPATCH and PROBE the
# resource WITHOUT the core knowing the resource itself:
#   COMMAND   the `yard <COMMAND>` verb that drives it           (default: the descriptor <name>)
#   HANDLER   profile-relative executable that owns ALL verbs (incl. the silent `is-up` probe)
#   TITLE     one-line description (status / help)
#   VERBS     space-separated verbs the handler accepts          (completion / help)
#   BRINGUP   the verb that brings it up, for the status hint     (default: up)
#   SHUTDOWN  the verb that stops it, for the status hint          (default: down)
#
# The resource's MECHANICS live entirely under its profile-owned HANDLER directory —
# launch/bridge/lease/seed differ per kind and
# are deliberately NOT unified (see lib-service.sh). This registry is the ONLY thing the core
# (bin/yard) and lib-service.sh consult, so adding a resource is "drop a .res + write a handler",
# with no per-feature edits to the core. Sourced by bin/yard and scripts/lib-service.sh.
[ -n "${SUBYARD_LIBRES_SOURCED:-}" ] && return 0
SUBYARD_LIBRES_SOURCED=1

_LIBRES_PROFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/profiles"

# Emit one TAB-separated row per descriptor, fields in this order (TITLE last — it may hold spaces):
#   profile  name  command  handler  bringup  shutdown  verbs  title
# Each descriptor is sourced in a SUBSHELL so its keys never leak into the caller.
res_rows() {
  local f name profile
  for f in "$_LIBRES_PROFILES"/*/resources/*.res; do
    [ -r "$f" ] || continue
    name="$(basename "$f" .res)"
    profile="$(basename "$(dirname "$(dirname "$f")")")"
    ( COMMAND=""; HANDLER=""; TITLE=""; VERBS=""; BRINGUP="up"; SHUTDOWN="down"
      # shellcheck disable=SC1090
      . "$f" >/dev/null 2>&1
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$profile" "$name" "${COMMAND:-$name}" "${HANDLER:-}" "${BRINGUP:-up}" \
        "${SHUTDOWN:-down}" "${VERBS:-}" "${TITLE:-}" )
  done
}

# Resource NAMES a given profile declares (descriptor basenames). Back-compat shape for
# svc_resources_for (which historically returned the profile's SHARED_RESOURCES names).
res_names_for_profile() {
  local want="$1" f
  for f in "$_LIBRES_PROFILES/$want"/resources/*.res; do
    [ -r "$f" ] && basename "$f" .res
  done
}

# Resolve one validated profile-relative handler without allowing a descriptor to escape its owner.
res_handler_path() {
  local profile="$1" handler="$2"
  case "$profile" in '' | -* | *[!A-Za-z0-9_-]*) return 1 ;; esac
  case "/$handler/" in
    *'/../'* | *'/./'* | *'//'*) return 1 ;;
  esac
  case "$handler" in '' | /* | -* | *[!A-Za-z0-9_./-]*) return 1 ;; esac
  printf '%s/%s/%s\n' "$_LIBRES_PROFILES" "$profile" "$handler"
}

# Absolute handler path for a resource by COMMAND, then by NAME (empty + non-zero if unknown).
res_handler_for_command() {
  local want="$1" p n c h found_profile='' found_handler=''
  while IFS=$'\t' read -r p n c h _; do
    [ "$c" = "$want" ] && { found_profile="$p"; found_handler="$h"; }
  done < <(res_rows)
  [ -n "$found_handler" ] || return 1
  res_handler_path "$found_profile" "$found_handler"
}
res_handler_for_name() {
  local want="$1" p n c h found_profile='' found_handler=''
  while IFS=$'\t' read -r p n c h _; do
    [ "$n" = "$want" ] && { found_profile="$p"; found_handler="$h"; }
  done < <(res_rows)
  [ -n "$found_handler" ] || return 1
  res_handler_path "$found_profile" "$found_handler"
}
res_handler_for() { res_handler_for_command "$1" || res_handler_for_name "$1"; }

res_registry_validate() {
  local p n c h b s v t path seen_names=' ' seen_commands=' '
  while IFS=$'\t' read -r p n c h b s v t; do
    [ -n "$p" ] && [ -n "$n" ] && [ -n "$c" ] && [ -n "$h" ] && [ -n "$b" ] \
      && [ -n "$s" ] && [ -n "$v" ] && [ -n "$t" ] || return 1
    case "$n$c$b$s" in *[!A-Za-z0-9_-]*) return 1 ;; esac
    case " $seen_names " in *" $n "*) return 1 ;; esac
    case " $seen_commands " in *" $c "*) return 1 ;; esac
    seen_names+="$n "; seen_commands+="$c "
    path="$(res_handler_path "$p" "$h")" && [ -x "$path" ] || return 1
    case "$v" in *[!A-Za-z0-9_[:space:]-]*) return 1 ;; esac
    case " $v " in *" $b "*) ;; *) return 1 ;; esac
    case " $v " in *" $s "*) ;; *) return 1 ;; esac
  done < <(res_rows)
}

# All resource COMMANDs (drives COMMANDS / --list / completion).
res_commands() { local p n c; while IFS=$'\t' read -r p n c _; do printf '%s\n' "$c"; done < <(res_rows); }

# "<command> <bringup>" for a resource NAME — the status bring-up hint (without the prog name).
res_hint_for_name() {
  local want="$1" p n c h b s found=''
  while IFS=$'\t' read -r p n c h b s _; do [ "$n" = "$want" ] && found="$c $b"; done < <(res_rows)
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

# "<command> <shutdown>" for a resource NAME — the status stop hint (without the prog name).
res_stop_hint_for_name() {
  local want="$1" p n c h b s found=''
  while IFS=$'\t' read -r p n c h b s _; do [ "$n" = "$want" ] && found="$c $s"; done < <(res_rows)
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

# "<command>\t<verbs>" per resource — consumed by the shell completions (generic verb lists).
res_completion_rows() {
  local p n c h b s v; while IFS=$'\t' read -r p n c h b s v _; do printf '%s\t%s\n' "$c" "$v"; done < <(res_rows)
}

# yard_profiles_active — the profiles ACTIVE in the current yard context, one per line: the
# yard's YARD_PROFILES when set, else every profile dir on disk (default-yard behavior). Lets a
# named yard surface only its own profiles' resources (status listing, per-yard provisioning).
yard_profiles_active() {
  if [ -n "${YARD_PROFILES:-}" ]; then
    local p
    for p in $YARD_PROFILES; do printf '%s\n' "$p"; done
  else
    local d
    for d in "$_LIBRES_PROFILES"/*/; do [ -d "$d" ] && basename "$d"; done
  fi
}
