#!/usr/bin/env bash
# yard-ssh.sh — target-aware shell/exec.
#   yard ssh [-- cmd...]            dev shell in the yard (L1), or run a command there
#   yard ssh <project> [-- cmd...]  if the project's target is an L2 profile box,
#                                   open a shell (or run -- cmd) INSIDE that box
# The first non-option token is treated as a PROJECT selector ONLY when it resolves to a
# known project whose target is a profile (not `yard`); otherwise every arg passes to ssh
# (L1). A target=yard project name is not an ssh host, so we fall back to a plain L1 shell.
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
      # L2 box: drop the selector, hand the rest (incl. `-- cmd`) to the project-env runner.
      rest=(); dropped=0
      for a in "$@"; do
        if [ "$dropped" = 0 ] && [ "$a" = "$first" ]; then dropped=1; continue; fi
        rest+=("$a")
      done
      if [ "${#rest[@]}" -gt 0 ]; then
        exec "$SCRIPT_DIR/project-env.sh" exec "$first" "${rest[@]}"
      fi
      exec "$SCRIPT_DIR/project-env.sh" shell "$first"
    fi
  fi
fi

# Default: dev shell in the yard (L1), or run a command there.
exec ssh "$SSH_HOST" "$@"
