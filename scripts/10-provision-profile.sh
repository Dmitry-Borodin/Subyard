#!/usr/bin/env bash
# 10-provision-profile.sh — Phase 4: install a project profile's TOOLCHAIN INTO THE YARD (L1), so an
# agent working directly in the yard (P1 baseline — no per-agent container) can build and run tests.
# For each profile it sources config/profiles/<name>/profile.conf (the non-secret contract) and runs
# that profile's config/profiles/<name>/provision.sh INSIDE the yard via `incus exec -- bash -s`,
# forwarding the contract vars as --env. Idempotent (each provision.sh self-guards). HEAVY (downloads
# toolchains) and explicit — never auto-run by a plain `yard agent up`.
#
# Usage: yard provision [<profile>]   — no arg: the UNION of profiles across in-yard projects (state).
# Operator-run (incus-admin); the in-yard work runs as root inside the yard. The host is untouched.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

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

# -l/--list: just show the provisionable profiles and exit (no prompt, no changes).
# (lib.sh already consumed -y/-h; an explicit profile name is the first non-option arg.)
want=""
for a in "$@"; do
  case "$a" in
    -l | --list)
      mapfile -t _all < <(disk_profiles)
      if [ "${#_all[@]}" -gt 0 ]; then
        printf 'Provisionable profiles (ship a provision.sh):\n'; printf '  • %s\n' "${_all[@]}"
      else printf 'No provisionable profile under %s\n' "$PROFILES_DIR"; fi
      exit 0 ;;
    -*) ;;
    *)  want="$a"; break ;;
  esac
done

# Which profiles to provision:
#   • an explicit arg                  → just that one;
#   • else the set registered by in-yard projects (state);
#   • else (no project registers one)  → ALL provisionable profiles on disk, so a bare
#     `yard provision` still has something to OFFER — listed + confirmed below, never silent.
if [ -n "$want" ]; then
  profiles=("$want"); src="requested"
else
  mapfile -t profiles < <(for id in $(state_ids); do state_get "$id" profile; done | sed '/^$/d' | sort -u)
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
  "Provision ALL of these profiles ($src): ${todo[*]} — into the yard (L1), not a per-agent container." \
  "Each profile runs its provision.sh inside the yard (downloads Node/JDK/SDK/etc.); idempotent." \
  "HEAVY (network + disk). The yard is shared and rebuildable; the host is untouched."
proceed_or_die   # lists the profiles above, then asks "Proceed? [y/N]" (default N) before any change

incus_preflight
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "instance '$INSTANCE_NAME' missing — run 'yard init' first"

for prof in "${todo[@]}"; do
  pf="$PROFILES_DIR/$prof/profile.conf"
  prov="$PROFILES_DIR/$prof/provision.sh"
  info "provisioning '$prof' toolchain into $INSTANCE_NAME …"
  (
    # Forward the profile's non-secret contract vars (KEY=… lines) as --env; provision.sh reads
    # what it needs. profile.conf is non-secret by taxonomy, so --env is fine; secrets live in
    # profile.env and are never sourced here.
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

ok "Phase 4 done — toolchain(s) installed into the yard."
