#!/usr/bin/env bash
# lib-resources.sh — the profile shared-resource REGISTRY (pure bash, no deps).
#
# A profile exposes long-lived in-yard services (the android profile: an emulator; the openclaw
# profile: a staging gateway + a QA bot-broker). Each is declared by a DESCRIPTOR file
#   config/profiles/<profile>/resources/<name>.res
# a sourced KEY=VALUE file that tells the yard core how to DISCOVER, DISPATCH and PROBE the
# resource WITHOUT the core knowing the resource itself:
#   COMMAND   the `yard <COMMAND>` verb that drives it           (default: the descriptor <name>)
#   HANDLER   the frontend script in scripts/ that owns ALL verbs (incl. the silent `is-up` probe)
#   TITLE     one-line description (status / help)
#   VERBS     space-separated verbs the handler accepts          (completion / help)
#   BRINGUP   the verb that brings it up, for the status hint     (default: up)
#
# The resource's MECHANICS live entirely in HANDLER — launch/bridge/lease/seed differ per kind and
# are deliberately NOT unified (see lib-service.sh). This registry is the ONLY thing the core
# (bin/yard) and lib-service.sh consult, so adding a resource is "drop a .res + write a handler",
# with no per-feature edits to the core. Sourced by bin/yard and scripts/lib-service.sh.
[ -n "${SUBYARD_LIBRES_SOURCED:-}" ] && return 0
SUBYARD_LIBRES_SOURCED=1

_LIBRES_PROFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/profiles"

# Emit one TAB-separated row per descriptor, fields in this order (TITLE last — it may hold spaces):
#   profile  name  command  handler  bringup  verbs  title
# Each descriptor is sourced in a SUBSHELL so its keys never leak into the caller.
res_rows() {
  local f name profile
  for f in "$_LIBRES_PROFILES"/*/resources/*.res; do
    [ -r "$f" ] || continue
    name="$(basename "$f" .res)"
    profile="$(basename "$(dirname "$(dirname "$f")")")"
    ( COMMAND=""; HANDLER=""; TITLE=""; VERBS=""; BRINGUP="up"
      # shellcheck disable=SC1090
      . "$f" >/dev/null 2>&1
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$profile" "$name" "${COMMAND:-$name}" "${HANDLER:-}" "${BRINGUP:-up}" "${VERBS:-}" "${TITLE:-}" )
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

# Handler script for a resource by COMMAND, then by NAME (echo empty + return 1 if unknown).
res_handler_for_command() {
  local want="$1" p n c h
  while IFS=$'\t' read -r p n c h _; do [ "$c" = "$want" ] && { printf '%s' "$h"; return 0; }; done < <(res_rows)
  return 1
}
res_handler_for_name() {
  local want="$1" p n c h
  while IFS=$'\t' read -r p n c h _; do [ "$n" = "$want" ] && { printf '%s' "$h"; return 0; }; done < <(res_rows)
  return 1
}
res_handler_for() { res_handler_for_command "$1" || res_handler_for_name "$1"; }

# All resource COMMANDs (drives COMMANDS / --list / completion).
res_commands() { local p n c; while IFS=$'\t' read -r p n c _; do printf '%s\n' "$c"; done < <(res_rows); }

# "<command> <bringup>" for a resource NAME — the status bring-up hint (without the prog name).
res_hint_for_name() {
  local want="$1" p n c h b
  while IFS=$'\t' read -r p n c h b _; do [ "$n" = "$want" ] && { printf '%s %s' "$c" "$b"; return 0; }; done < <(res_rows)
  return 1
}

# "<command>\t<verbs>" per resource — consumed by the shell completions (generic verb lists).
res_completion_rows() {
  local p n c h b v; while IFS=$'\t' read -r p n c h b v _; do printf '%s\t%s\n' "$c" "$v"; done < <(res_rows)
}
