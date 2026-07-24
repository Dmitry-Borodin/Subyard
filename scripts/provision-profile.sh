#!/usr/bin/env bash
# Run one Go-selected profile hook inside the yard.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/engine-context.sh
. "$SCRIPT_DIR/lib/engine-context.sh"
subyard_require_engine_context
profile="${1:-}"
case "$profile" in '' | *[!a-zA-Z0-9_-]*) printf 'provision: invalid profile\n' >&2; exit 2 ;; esac
root="$(cd "$SCRIPT_DIR/.." && pwd)"
config="$root/config/profiles/$profile/profile.conf"
hook="$root/config/profiles/$profile/provision.sh"
[ -r "$config" ] && [ -r "$hook" ] || { printf 'provision: profile hook missing\n' >&2; exit 1; }

env_args=(--env DEV_USER="${DEV_USER:-dev}")
# shellcheck disable=SC1090
. "$config"
while IFS= read -r name; do
  [ -z "$name" ] || env_args+=(--env "$name=${!name-}")
done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$config" | sed 's/=$//' | sort -u)
exec incus exec "${INSTANCE_NAME:?}" --project "${INCUS_PROJECT:?}" "${env_args[@]}" \
  -- bash -euo pipefail -s < "$hook"
