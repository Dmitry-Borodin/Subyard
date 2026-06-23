#!/usr/bin/env bash
# project-export.sh — Phase 7b (slice): pull the agent's work in the yard back to the
# host as a reviewable patch. The counterpart to `sync` for sync-mode projects.
# Usage: project-export.sh [path]   (default '.')
# Diffs the yard copy against the host copy and writes a unified patch you review and
# apply yourself (git apply -p1 / patch -p1), keeping the host copy isolated.
# Transport mirrors sync: a tar stream over `incus exec`.
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
PROJ=(--project "$INCUS_PROJECT")

# --- parse args --------------------------------------------------------------
path="."
for a in "$@"; do
  case "$a" in
    -y | --yes) ;;                       # no mutation on host beyond writing a patch file
    -*)         die "unknown option '$a'" ;;
    *)          path="$a" ;;
  esac
done
[ -d "$path" ] || die "not a directory: $path"

# --- resolve identity / state ------------------------------------------------
hostPath="$(realpath -- "$path")"
id="$(project_id "$hostPath")"
name="$(basename -- "$hostPath")"
state_exists "$id" || die "'$name' is not in the yard — run: ${PROG:-yard} sync $path"
yardPath="$(state_get "$id" yardPath)"
mode="$(state_get "$id" mode)"
if [ "$mode" = bind ]; then
  die "'$name' is a bind project — its changes are already on the host; nothing to export"
fi

# --- preflight: yard must be running -----------------------------------------
command -v incus >/dev/null 2>&1 || die "incus not found — run 'yard init' first"
[ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ] \
  || die "yard is not running — start it: ${PROG:-yard} up"
incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- test -d "$yardPath" \
  || die "yard copy missing at $yardPath — re-run: ${PROG:-yard} sync $path"

# --- materialise both sides into a temp tree and diff ------------------------
# a/ = host copy, b/ = yard copy; relative a/ b/ prefixes so the patch applies with
# `git apply` / `patch -p1`. .git is excluded — we export the working tree, not history.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/yard-export.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/a" "$tmp/b"

info "snapshotting host copy …"
tar -C "$hostPath" --exclude=.git -cf - . | tar -C "$tmp/a" -xf - || die "could not read host copy"
info "pulling yard copy from $INSTANCE_NAME:$yardPath …"
incus exec "$INSTANCE_NAME" "${PROJ[@]}" --user "$DEV_UID" --group "$DEV_UID" -- \
  tar -C "$yardPath" --exclude=.git -cf - . | tar -C "$tmp/b" -xf - || die "could not read yard copy"

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
