#!/usr/bin/env bash
# yard-authorize.sh — `yard _authorize`: HIDDEN, runs ON the yard's OWNER host (where incus
# lives). Reads ONE ssh public key from stdin and idempotently authorizes it for the yard's
# dev user, so a remote operator's ProxyJump alias (`yard-<name>`) can reach the yard.
#   - invoked over ssh by `yard remote add` on the controller: the pubkey is piped in;
#   - no announce/prompt (it runs inside the operator's own ssh session, already trusted),
#     but it prints ONE ok/info line to stderr so `remote add` can echo progress;
#   - works under a named context (-Y <name>) — it uses the loaded INSTANCE_NAME/project;
#   - exits non-zero with a clear message when the instance is missing or not running
#     (authorized_keys is written via `incus exec`, which needs the yard up).
# Config: config/incus.project.env + config/subyard.env (+ the -Y context layer).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_USER="${DEV_USER:-dev}"
PROJ=(--project "$INCUS_PROJECT")

# Read the single pubkey line from stdin (first non-empty line wins; ignore trailing lines).
PUBKEY=''
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  PUBKEY="$line"; break
done
[ -n "$PUBKEY" ] || die "_authorize: no public key on stdin"

# Validate it looks like an OpenSSH public key: a known key type, then a base64 blob. Reject
# anything else before it reaches the yard (we never want to append junk to authorized_keys).
case "$PUBKEY" in
  ssh-ed25519\ *|ssh-rsa\ *|ssh-dss\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|\
ecdsa-sha2-nistp521\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-nistp256@openssh.com\ *) ;;
  *) die "_authorize: stdin does not look like an ssh public key (got: ${PUBKEY%% *} …)" ;;
esac
# Second field must be a base64 blob (letters/digits/+//=), no shell metacharacters.
_blob="${PUBKEY#* }"; _blob="${_blob%% *}"
case "$_blob" in ''|*[!A-Za-z0-9+/=]*) die "_authorize: malformed key material" ;; esac

# The yard must be reachable and running — authorized_keys is written from inside it.
incus_preflight _authorize
incus info "$INSTANCE_NAME" "${PROJ[@]}" >/dev/null 2>&1 \
  || die "_authorize: instance '$INSTANCE_NAME' missing on this host — run '$(yard_cmd_hint) init' first"
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null | head -n1)" = RUNNING ] \
  || die "_authorize: yard '$INSTANCE_NAME' is not running — start it: $(yard_cmd_hint) start"

# Idempotent append (create ~/.ssh + authorized_keys with dev ownership if missing), mirrors
# 07-ssh-access.sh's authorize step. Prints 'added'/'already present' so the caller can relay it.
result="$(incus exec "$INSTANCE_NAME" "${PROJ[@]}" --env PUBKEY="$PUBKEY" --env DEV_USER="$DEV_USER" -- sh -eu -c '
  home="$(getent passwd "$DEV_USER" | cut -d: -f6)"
  [ -n "$home" ] || { echo "no home for $DEV_USER" >&2; exit 3; }
  install -d -m 700 -o "$DEV_USER" -g "$DEV_USER" "$home/.ssh"
  ak="$home/.ssh/authorized_keys"; touch "$ak"
  if grep -qxF "$PUBKEY" "$ak"; then printf already; else printf "%s\n" "$PUBKEY" >> "$ak"; printf added; fi
  chmod 600 "$ak"; chown "$DEV_USER":"$DEV_USER" "$ak"
')" || die "_authorize: could not write authorized_keys in the yard"

case "$result" in
  added)   printf '  [ ok ] authorized the controller key for %s in %s\n' "$DEV_USER" "$INSTANCE_NAME" >&2 ;;
  already) printf '  [ ok ] controller key already authorized for %s in %s\n' "$DEV_USER" "$INSTANCE_NAME" >&2 ;;
  *)       die "_authorize: unexpected result from the yard: $result" ;;
esac
