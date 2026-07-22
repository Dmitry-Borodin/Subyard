#!/usr/bin/env bash
# Read the optional local enrollment request.

[ -n "${SUBYARD_E2E_AGENT_ENROLLMENT_SOURCED:-}" ] && return 0
SUBYARD_E2E_AGENT_ENROLLMENT_SOURCED=1

# Sets the normalized key and fingerprint; returns 1 if absent, 2 if invalid.
e2e_agent_enrollment_read() {
  local directory="$1" file type blob comment line_count fingerprint
  file="$directory/agent-access.pub"
  E2E_AGENT_PUBLIC_KEY=''
  E2E_AGENT_PUBLIC_KEY_FINGERPRINT=''
  [ -e "$file" ] || return 1
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 2
  line_count="$(wc -l < "$file")" || return 2
  [ "$line_count" -eq 1 ] || return 2
  IFS=' ' read -r type blob comment < "$file" || return 2
  [ "$type" = ssh-ed25519 ] && [[ "$blob" =~ ^[A-Za-z0-9+/=]+$ ]] || return 2
  [[ "$comment" != *$'\r'* ]] || return 2
  fingerprint="$(ssh-keygen -lf "$file" 2>/dev/null | awk 'NR == 1 { print $2 }')" || return 2
  [ -n "$fingerprint" ] || return 2
  # shellcheck disable=SC2034 # sourced output
  E2E_AGENT_PUBLIC_KEY="$type $blob"
  # shellcheck disable=SC2034 # sourced output
  E2E_AGENT_PUBLIC_KEY_FINGERPRINT="$fingerprint"
}
