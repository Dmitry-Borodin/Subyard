#!/usr/bin/env bash
# project-export.sh — Phase 7b (slice): pull the agent's work in the yard back to the
# host as a reviewable patch. The counterpart to `sync` for sync-mode projects.
# Usage: project-export.sh [path]   (default '.')
# Diffs the yard copy against the host copy and writes a unified patch you review and
# apply yourself (git apply -p1 / patch -p1), keeping the host copy isolated.
# Transport mirrors sync: a tar stream over `incus exec` for a local yard, or over the
# yard-<name> ssh alias for a remote yard (no local incus).
# Operator-owned; no root. Config: config/incus.project.env + config/subyard.env + config/host.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/lib-state.sh
. "$SCRIPT_DIR/lib-state.sh"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
DEV_UID="${DEV_UID:-1000}"
SSH_HOST="${SSH_HOST:-yard}"   # remote yards read the yard copy over this alias
PROJ=(--project "$INCUS_PROJECT")

# --- parse args --------------------------------------------------------------
# Accept a path (default '.'), an exact id, or a project NAME from `yard list`.
arg="."
for a in "$@"; do
  case "$a" in
    -y | --yes) ;;                       # no mutation on host beyond writing a patch file
    -*)         die "unknown option '$a'" ;;
    *)          arg="$a" ;;
  esac
done

# --- resolve identity / state ------------------------------------------------
# resolve_project_ctx resolves across yards and re-execs in the owning yard when it lives elsewhere.
resolve_project_ctx "$arg"
id="$RESOLVED_ID"
name="$(state_get "$id" name)"; name="${name:-$id}"
hostPath="$(state_get "$id" hostPath)"
yardPath="$(state_get "$id" yardPath)"
mode="$(state_get "$id" mode)"
case "$mode" in
  bind) die "'$name' is a bind project — its changes are already on the host; nothing to export" ;;
  git)  die "'$name' is a git-mode clone (no host copy) — pull changes with git inside the yard, not export" ;;
esac
[ -d "$hostPath" ] || die "host copy is gone ($hostPath) — cannot diff; re-add it with ${PROG:-yard} sync <path>"

# --- preflight: yard must be reachable, yard copy must exist -----------------
# Remote: probe the ssh alias (never incus) and test the copy over it. Local: incus.
if yard_is_remote; then
  require_remote_reachable
  ssh "$SSH_HOST" -- test -d "$yardPath" \
    || die "yard copy missing at $yardPath — re-run: ${PROG:-yard} sync $arg"
else
  incus_preflight
  [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
    || die "yard is not running — start it: ${PROG:-yard} start"
  incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- test -d "$yardPath" \
    || die "yard copy missing at $yardPath — re-run: ${PROG:-yard} sync $arg"
fi

# --- materialise both sides into a temp tree and diff ------------------------
# a/ = host copy, b/ = yard copy; relative a/ b/ prefixes so the patch applies with
# `git apply` / `patch -p1`. .git is excluded — we export the working tree, not history.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/yard-export.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/a" "$tmp/b"

info "snapshotting host copy …"
tar -C "$hostPath" --exclude=.git -cf - . | tar -C "$tmp/a" -xf - || die "could not read host copy"
if yard_is_remote; then
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

# --- persist the patch on the host -------------------------------------------
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
