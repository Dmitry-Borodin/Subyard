#!/usr/bin/env bash
# yard-ssh.sh — target-aware shell/exec.
#   yard ssh [-- cmd...]            dev shell in the yard (L1), or run a command there
#   yard ssh <project> [-- cmd...]  if the project's target is an L2 profile box,
#                                   open a shell (or run -- cmd) INSIDE that box
# The first non-option token is treated as a PROJECT selector ONLY when it resolves to a
# known project whose target is a profile (not `yard`); otherwise every arg passes to ssh
# (L1). A target=yard project name is not an ssh host, so we fall back to a plain L1 shell.
# Remote yards (YARD_TYPE=remote): the L1 shell path is plain `ssh $SSH_HOST` over the
# yard-<name> alias and works unchanged; an L2-box selector cannot be reached from here
# (boxes are managed on the owner host), so it degrades to an L1 shell with a warning.
# Operator-owned; no root. Config: config/subyard.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

# ssh host alias (host-side ssh config), named in config/subyard.env.
SSH_HOST="${SSH_HOST:-yard}"
if [ -r "$SCRIPT_DIR/../config/subyard.env" ]; then
  SSH_HOST="$( . "$SCRIPT_DIR/../config/subyard.env" >/dev/null 2>&1; printf '%s' "${SSH_HOST:-yard}")"
fi

# Soft project resolver: print the id if <arg> names a known project, else fail (no die).
resolve_soft() {
  local arg="$1" id nm
  [ -n "$arg" ] || return 1
  if [ -e "$arg" ]; then
    id="$(project_id "$arg" 2>/dev/null || true)"
    [ -n "$id" ] && state_exists "$id" && { printf '%s' "$id"; return 0; }
  fi
  state_exists "$arg" && { printf '%s' "$arg"; return 0; }
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    nm="$(state_get "$id" name)"
    [ "${nm,,}" = "${arg,,}" ] && { printf '%s' "$id"; return 0; }
  done < <(state_ids)
  return 1
}

# Peek the first project-selector token: the first arg that is not an option and comes
# before a `--`. Options and `-- cmd...` pass straight through to ssh / the box exec.
first=""
for a in "$@"; do
  case "$a" in
    -y|--yes) ;;
    --) break ;;
    -*) break ;;        # an ssh option → plain L1 ssh
    *)  first="$a"; break ;;
  esac
done

if [ -n "$first" ]; then
  if id="$(resolve_soft "$first")"; then
    target="$(state_get "$id" target)"
    if [ -n "$target" ] && [ "$target" != yard ]; then
      # Drop the selector; keep the rest (incl. `-- cmd`) to hand on.
      rest=(); dropped=0
      for a in "$@"; do
        if [ "$dropped" = 0 ] && [ "$a" = "$first" ]; then dropped=1; continue; fi
        rest+=("$a")
      done
      if yard_is_remote; then
        # The L2 box lives on the owner host; there is no local Docker to reach it. Degrade to
        # an L1 shell in the remote yard and point at where the box is actually managed.
        warn "'$first' runs in an L2 box, managed on the yard's owner host — opening an L1 shell in the remote yard instead (manage it there: ssh ${REMOTE_DEST:-<dest>} yard${REMOTE_YARD:+ -Y $REMOTE_YARD} up $first)"
        exec ssh "$SSH_HOST" ${rest[@]+"${rest[@]}"}
      fi
      # L2 box (local): hand the rest to the project-env runner.
      if [ "${#rest[@]}" -gt 0 ]; then
        exec "$SCRIPT_DIR/project-env.sh" exec "$first" "${rest[@]}"
      fi
      exec "$SCRIPT_DIR/project-env.sh" shell "$first"
    fi
  fi
fi

# Default: dev shell in the yard (L1), or run a command there.
exec ssh "$SSH_HOST" "$@"
