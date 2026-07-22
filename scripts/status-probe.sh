#!/usr/bin/env bash
# status-probe.sh — structured read-only facts kept at the shell/profile safety boundary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "${SUBYARD_ENGINE_CONTEXT:-}" = 1 ] || { printf 'status-probe: prepared engine context required\n' >&2; exit 2; }
# shellcheck source=scripts/lib/env.sh
. "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"
case "${1:-}" in running) running=1 ;; stopped) running=0 ;; *) die "status probe expects running or stopped" ;; esac

if "$SCRIPT_DIR/security-lint.sh" --quiet --require-live >/dev/null 2>&1; then
  security=live
elif "$SCRIPT_DIR/security-lint.sh" --quiet >/dev/null 2>&1; then
  security=static-only
else
  security=FAIL
fi

space_cache="$SUBYARD_HOME/space${YARD_NAME:+-$YARD_NAME}.cache"
space_ttl="${SPACE_TTL:-600}"
figure='' epoch=0 now="$(date +%s)" note=''
if [ -f "$space_cache" ]; then read -r figure epoch < "$space_cache" || true; fi
case "$epoch" in ''|*[!0-9]*) figure=''; epoch=0 ;; esac
if [ "$running" = 1 ] && { [ -z "$figure" ] || [ $((now - epoch)) -gt "$space_ttl" ]; }; then
  (
    install -d -m 700 "$SUBYARD_HOME"
    flock -n 9 || exit 0
    measured="$(incus exec "$INSTANCE_NAME" --project "$INCUS_PROJECT" -- sh -c '
      set --
      while read -r _ mp _; do case "$mp" in /|/srv) ;; *) set -- "$@" "--exclude=$mp" ;; esac; done < /proc/mounts
      du -sxh "$@" / 2>/dev/null' | awk '{print $1}' || true)"
    [ -n "$measured" ] || exit 0
    printf '%s %s\n' "$measured" "$(date +%s)" > "$space_cache.tmp" && mv -f "$space_cache.tmp" "$space_cache"
  ) 9>"$space_cache.lock" </dev/null >/dev/null 2>&1 &
  [ -z "$figure" ] || note=', refreshing'
fi
if [ -n "$figure" ]; then
  space="${figure}  (in-yard rootfs, $(age_human $((now - epoch))) ago${note})"
elif [ "$running" = 1 ]; then
  space='measuring in the yard — re-run status in a moment'
else
  space="—  (yard stopped; on-host size: sudo du -sh $SUBYARD_HOME)"
fi

jq -cn --arg security "$security" --arg space "$space" '{security:$security,space:$space}'
