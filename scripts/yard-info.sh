#!/usr/bin/env bash
# yard-info.sh — `yard _info`: machine-readable one-line JSON describing THIS yard context.
# A probe, not a command: no announce/prompt, no audit noise, and it ALWAYS exits 0 — when
# incus is unreachable the state is reported as "UNKNOWN" rather than dying (the remote probe
# and `yard yards`/`status --all` rely on that). A running yard's project count comes from its
# yard-side metadata; an unavailable observation is JSON null so controllers can use last-good
# cache without inventing zero. jq-free output (printf), but jq-parseable.
#   {"name":…,"type":"local","version":…,"instance":…,"project":…,
#    "state":"RUNNING|STOPPED|UNKNOWN","sshHost":…,"sshPort":N,"devUser":…,"projects":N|null}
# Config: config/incus.project.env + config/subyard.env + config/host.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
SSH_HOST="${SSH_HOST:-yard}"
DEV_USER="${DEV_USER:-dev}"
PROJ=(--project "$INCUS_PROJECT")

name="${YARD_NAME:-default}"
version="${YARD_VERSION:-unknown}"

# State: only when the daemon actually answers. Absent/unreachable incus → UNKNOWN (never die).
# Reachable but the instance is missing/stopped → STOPPED. Anything else passes through.
state=UNKNOWN
if command -v incus >/dev/null 2>&1 && incus info >/dev/null 2>&1; then
  s="$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null | head -n1)"
  state="${s:-STOPPED}"
fi

# sshPort as a JSON number (default yard's comes from config; a named yard must set it). Fall
# back to 0 if somehow non-numeric, so the emitted JSON stays valid.
sshPort="${SSH_PORT:-0}"
case "$sshPort" in ''|*[!0-9]*) sshPort=0 ;; esac

# Only a successful read of the running yard can establish its inventory. Keep using portable
# yard metadata here: owner-host registry convergence is synchronous for new remote operations,
# but older clients or interrupted cross-host calls may still leave it temporarily incomplete.
projects=null
if [ "$state" = RUNNING ]; then
  projects="$(yard_live_project_count_local)" || projects=null
fi

printf '{"name":"%s","type":"local","version":"%s","instance":"%s","project":"%s","state":"%s","sshHost":"%s","sshPort":%s,"devUser":"%s","projects":%s}\n' \
  "$name" "$version" "$INSTANCE_NAME" "$INCUS_PROJECT" "$state" "$SSH_HOST" "$sshPort" "$DEV_USER" "$projects"
