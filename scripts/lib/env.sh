#!/usr/bin/env bash
# env.sh — dependency-free readers and formatters.

[ -n "${SUBYARD_ENV_SOURCED:-}" ] && return 0
SUBYARD_ENV_SOURCED=1

yard_env_val() { # <file> <KEY>
  sed -n "s/^[[:space:]]*$2=//p" "$1" 2>/dev/null | tail -n1 \
    | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}

age_human() {
  local seconds="$1"
  if [ "$seconds" -lt 60 ]; then printf '%ss\n' "$seconds"
  elif [ "$seconds" -lt 3600 ]; then printf '%sm\n' "$((seconds / 60))"
  elif [ "$seconds" -lt 86400 ]; then printf '%sh\n' "$((seconds / 3600))"
  else printf '%sd\n' "$((seconds / 86400))"; fi
}
