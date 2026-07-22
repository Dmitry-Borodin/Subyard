#!/usr/bin/env bash
# Physical export adapter. Go supplies the resolved project snapshot and context.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=scripts/lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"
# shellcheck source=scripts/lib/project-snapshot.sh
. "$SCRIPT_DIR/lib/project-snapshot.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_UID="${DEV_UID:-1000}"
SSH_HOST="${SSH_HOST:-yard}"   # remote yards read the yard copy over this alias
PROJ=(--project "$INCUS_PROJECT")

project_snapshot_load
case "$mode" in
  bind) die "'$name' is a bind project — its changes are already on the host; nothing to export" ;;
  git)  die "'$name' is a git-mode clone (no host copy) — pull changes with git inside the yard, not export" ;;
esac
[ -d "$hostPath" ] || die "host copy is gone ($hostPath) — cannot diff; re-add it with ${PROG:-yard} sync <path>"

if [ "${YARD_TYPE:-local}" = remote ]; then
  ssh "$SSH_HOST" -- test -d "$yardPath" \
    || die "yard copy missing at $yardPath — re-run: ${PROG:-yard} sync $id"
else
  incus_preflight
  [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
    || die "yard is not running — start it: ${PROG:-yard} start"
  incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- test -d "$yardPath" \
    || die "yard copy missing at $yardPath — re-run: ${PROG:-yard} sync $id"
fi

# Compare host and yard worktrees without Git history.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/yard-export.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/a" "$tmp/b"

info "snapshotting host copy …"
tar -C "$hostPath" --exclude=.git -cf - . | tar -C "$tmp/a" -xf - || die "could not read host copy"
if [ "${YARD_TYPE:-local}" = remote ]; then
  info "pulling yard copy from $SSH_HOST:$yardPath …"
  ssh "$SSH_HOST" -- tar -C "$yardPath" --exclude=.git -cf - . | tar -C "$tmp/b" -xf - \
    || die "could not read yard copy"
else
  info "pulling yard copy from $INSTANCE_NAME:$yardPath …"
  incus exec "$INSTANCE_NAME" "${PROJ[@]}" --user "$DEV_UID" --group "$DEV_UID" -- \
    tar -C "$yardPath" --exclude=.git -cf - . | tar -C "$tmp/b" -xf - || die "could not read yard copy"
fi

patch="$tmp/changes.patch"
set +e
( cd "$tmp" && diff -ruN a b ) > "$patch"
rc=$?
set -e
[ "$rc" -le 1 ] || die "diff failed (rc=$rc)"

if [ "$rc" -eq 0 ]; then
  ok "no changes in the yard — nothing to export ($name)"
  exit 0
fi

outdir="$SUBYARD_HOME/exports"; install -d -m 700 "$outdir"
out="$outdir/$id-$(date -u +%Y%m%dT%H%M%SZ).patch"
mv -f "$patch" "$out"; chmod 600 "$out"

changed="$(grep -cE '^(\+\+\+ |Only in )' "$out" || true)"
ok "exported $name — $changed file(s) differ"
info "patch: $out"
cat <<MSG

Review and apply on the host (from $hostPath):
  git -C "$hostPath" apply --stat "$out"     # preview
  git -C "$hostPath" apply "$out"            # apply (or: patch -p1 -d "$hostPath" < "$out")
MSG
