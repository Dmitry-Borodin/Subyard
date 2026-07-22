#!/usr/bin/env bash
# 10-provision-profile.sh — Phase 4: install a profile's toolchain into the yard (L1) by running its
# config/profiles/<name>/provision.sh inside the yard (incus exec), forwarding profile.conf vars as
# --env. Idempotent; HEAVY and explicit (never auto-run by `yard up`). Operator-run (incus-admin).
#
# Usage: yard provision [<profile>]   (no arg → all provisionable profiles; -l lists them)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Explicit control-plane module composition (config/context loads exactly once).
# shellcheck source=scripts/lib/runtime.sh
. "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=scripts/lib/env.sh
. "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/registry.sh
. "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=scripts/lib/context.sh
. "$SCRIPT_DIR/lib/context.sh"
# shellcheck source=scripts/lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=scripts/lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
subyard_context_load
# shellcheck source=scripts/lib/cache.sh
. "$SCRIPT_DIR/lib/cache.sh"
# shellcheck source=scripts/lib-power.sh
. "$SCRIPT_DIR/lib-power.sh"
# shellcheck source=scripts/lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"
INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_USER="${DEV_USER:-dev}"
PROFILES_DIR="$SCRIPT_DIR/../config/profiles"
PROJ=(--project "$INCUS_PROJECT")

# Profiles that ship a provision.sh — the provisionable universe (needs no incus/state).
disk_profiles() {
  local d
  for d in "$PROFILES_DIR"/*/; do [ -r "${d}provision.sh" ] && basename "$d"; done
}

# -l/--list: print provisionable profiles and exit. (ui.sh consumed -y/-h; first non-flag arg = profile.)
want=""
for a in "$@"; do
  case "$a" in
    -l | --list)
      mapfile -t _all < <(disk_profiles)
      if [ "${#_all[@]}" -gt 0 ]; then
        printf 'Provisionable profiles (ship a provision.sh):\n'; printf '  • %s\n' "${_all[@]}"
      else printf 'No provisionable profile under %s\n' "$PROFILES_DIR"; fi
      exit 0 ;;
    -y | --yes | -h | --help) ;;   # consumed by ui.sh; tolerate here
    -*) die "unknown option '$a'" ;;   # a typo'd flag must error, not be silently ignored
    *)  want="$a"; break ;;
  esac
done

# Which to provision: explicit arg → that one; else this yard's YARD_PROFILES UNION the profiles
# any registered project targets (a project pinned to a profile outside YARD_PROFILES must still
# be provisioned, not silently skipped); else state-registered profiles; else all on disk.
# The default yard sets no YARD_PROFILES, so its no-arg behavior is unchanged.
if [ -n "$want" ]; then
  profiles=("$want"); src="requested"
elif [ -n "${YARD_PROFILES:-}" ]; then
  # Union, YARD_PROFILES first then Go-resolved project profiles, order-stable and deduped.
  read -ra _yp <<<"$YARD_PROFILES"
  read -ra _st <<<"${SUBYARD_PROJECT_PROFILES:-}"
  declare -A _seen=(); profiles=()
  for prof in "${_yp[@]}" ${_st[@]+"${_st[@]}"}; do
    [ -n "$prof" ] && [ -z "${_seen[$prof]:-}" ] || continue
    _seen["$prof"]=1; profiles+=("$prof")
  done
  src="yard profiles (${YARD_NAME:-default}) ∪ in-yard projects"
else
  read -ra profiles <<<"${SUBYARD_PROJECT_PROFILES:-}"
  if [ "${#profiles[@]}" -gt 0 ]; then src="in-yard projects"
  else mapfile -t profiles < <(disk_profiles); src="available on disk — no in-yard project registers a profile"; fi
fi
[ "${#profiles[@]}" -gt 0 ] || { ok "No provisionable profile found. Nothing to do."; exit 0; }

# Keep only profiles that actually ship a provision.sh.
todo=()
for prof in "${profiles[@]}"; do
  if [ -r "$PROFILES_DIR/$prof/provision.sh" ]; then todo+=("$prof")
  else warn "profile '$prof' has no provision.sh — skipping"; fi
done
[ "${#todo[@]}" -gt 0 ] || { ok "No profile with a provision.sh — nothing to do."; exit 0; }

announce "Subyard Phase 4 — provision profile toolchain into the yard ($INSTANCE_NAME)" \
  "Provision ALL of these profiles ($src): ${todo[*]} — into the yard (L1), not a per-project-env box." \
  "Each profile runs its provision.sh inside the yard (downloads Node/JDK/SDK/etc.); idempotent." \
  "HEAVY (network + disk). The yard is shared and rebuildable; the host is untouched."
proceed_or_die

incus_preflight
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "instance '$INSTANCE_NAME' missing — run '$(yard_cmd_hint) init' first"

# A named yard is stopped by default. Provision may start it technically, but that must not opt it
# into boot restoration: preserve desired_power and stop it again on success or failure.
BRIDGE="${INCUS_BRIDGE:-${INCUS_NETWORK:-incusbr0}}"
YARD_LABEL="${YARD_NAME:-default}"
power_import_instance "$INCUS_PROJECT" "$INSTANCE_NAME" "$YARD_LABEL" "$BRIDGE" \
  || die "$POWER_ERROR"
desired_power="$(power_get "$INCUS_PROJECT" "$INSTANCE_NAME" "$POWER_KEY_DESIRED")"
temporary_start=0
current_power="$(power_state "$INCUS_PROJECT" "$INSTANCE_NAME")"
if [ "$current_power" != RUNNING ]; then
  [ "$current_power" = STOPPED ] \
    || die "cannot provision while yard state is '${current_power:-unknown}'"
  power_nm_prepare_reader || die "$POWER_ERROR"
  info "temporarily starting $INSTANCE_NAME for provision (desired=$desired_power)"
  power_start_guarded "$INCUS_PROJECT" "$INSTANCE_NAME" "$BRIDGE" || die "$POWER_ERROR"
  [ "$desired_power" != stopped ] || temporary_start=1
fi

restore_temporary_power() {
  local rc=$?
  trap - EXIT
  if [ "$temporary_start" = 1 ]; then
    info "restoring $INSTANCE_NAME to desired=stopped"
    power_stop_instance "$INCUS_PROJECT" "$INSTANCE_NAME" \
      || { warn "$POWER_ERROR"; rc=1; }
  fi
  exit "$rc"
}
trap restore_temporary_power EXIT

for prof in "${todo[@]}"; do
  pf="$PROFILES_DIR/$prof/profile.conf"
  prov="$PROFILES_DIR/$prof/provision.sh"
  info "provisioning '$prof' toolchain into $INSTANCE_NAME …"
  (
    # Forward profile.conf's (non-secret) KEY= vars as --env; secrets live in profile.env, never here.
    env_args=(--env DEV_USER="$DEV_USER")
    if [ -r "$pf" ]; then
      # shellcheck disable=SC1090
      . "$pf"
      while IFS= read -r k; do
        [ -n "$k" ] && env_args+=(--env "$k=${!k-}")
      done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$pf" | sed 's/=$//' | sort -u)
    fi
    incus exec "$INSTANCE_NAME" "${PROJ[@]}" "${env_args[@]}" -- bash -euo pipefail -s < "$prov"
  ) || die "profile '$prof' provisioning failed"
  ok "provisioned '$prof'"
done

if [ "$temporary_start" = 1 ]; then
  info "restoring $INSTANCE_NAME to desired=stopped"
  power_stop_instance "$INCUS_PROJECT" "$INSTANCE_NAME" || die "$POWER_ERROR"
  temporary_start=0
fi
trap - EXIT
ok "Phase 4 done — toolchain(s) installed into the yard."
