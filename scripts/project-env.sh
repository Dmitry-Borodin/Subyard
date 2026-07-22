#!/usr/bin/env bash
# Physical L2 up/info/down adapter. Go supplies the project snapshot and options.
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
PROFILES_DIR="$SCRIPT_DIR/../config/profiles"
PROJ=(--project "$INCUS_PROJECT")

yexec()   { incus exec "$INSTANCE_NAME" "${PROJ[@]}" -- "$@"; }
ydocker() { yexec docker "$@"; }

SESSIONS_ROOT="/mnt/host/agent-sessions"

# Link configured agent session directories into the box.
link_box_sessions() {
  local cname="$1" name target kind
  [ -n "${HOST_LINKS:-}" ] || return 0
  printf '%s\n' "$HOST_LINKS" | sed 's/[[:space:]]//g' | while IFS=: read -r name target kind; do
    [ -n "$name" ] && [ -n "$target" ] || continue
    [ "$kind" = file ] && continue   # single-writer files (db) are not shared into the box
    ydocker exec -u 0 "$cname" sh -c '
      name="$1"; target="$2"; uid="$3"
      home="$(getent passwd "$uid" | cut -d: -f6)"; home="${home:-/home/dev}"
      link="$home/$name"
      [ -d "$(dirname "$target")" ] || { echo "skip $name -> $target (session store not mounted)" >&2; exit 0; }
      install -d -o "$uid" -g "$uid" "$target" 2>/dev/null || true
      install -d -o "$uid" -g "$uid" "$(dirname "$link")" 2>/dev/null || true
      if [ -L "$link" ] || [ ! -e "$link" ]; then
        ln -sfn "$target" "$link"; chown -h "$uid:$uid" "$link"
      else
        echo "WARNING: $link exists and is not a symlink in the box — leaving it" >&2
      fi
    ' _ "$name" "$target" "$DEV_UID" || true
  done
}

# Profile control keys are not injected into the box.
is_control_key() {
  case "$1" in
    PROFILE_NAME|BASE_IMAGE|CACHES|DEVICES|OPTIONAL_FEATURES|IMAGE_DOCKERFILE|IMAGE_CONTEXT|IMAGE_TAG|\
    ENV_MOUNTS|YARD_MOUNTS|YARD_CAPS|YARD_DEVICES)
      return 0 ;;
    *) return 1 ;;
  esac
}

# Public capability manifest; secret values are never included.
manifest_json() {
  local feats="" caches="" envkeys="" secs="" devs="" k
  for k in ${OPTIONAL_FEATURES:-}; do feats+="\"$k\","; done
  for k in ${CACHES:-};           do caches+="\"$k\","; done
  for k in ${DEVICES:-};          do devs+="\"$k\","; done
  while IFS= read -r k; do
    is_control_key "$k" && continue
    envkeys+="\"$k\","
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$pf" | cut -d= -f1 | sort -u)
  [ "${have_secrets:-0}" = 1 ] && secs="{\"name\":\"profile.env\",\"path\":\"/run/subyard/profile.env\"}"
  cat <<JSON
{
  "profile": "$profile",
  "image": "${run_image:-$BASE_IMAGE}",
  "baseImage": "$BASE_IMAGE",
  "features": [${feats%,}],
  "caches": [${caches%,}],
  "envKeys": [${envkeys%,}],
  "secrets": [${secs}],
  "devices": [${devs%,}]
}
JSON
}

yard_running() { [ "$(incus list "$INSTANCE_NAME" "${PROJ[@]}" -f csv -c s 2>/dev/null)" = RUNNING ]; }
preflight() {
  incus_preflight
  yard_running || die "yard is not running — start it: ${PROG:-yard} start"
}

sub="${1:-}"
case "$sub" in up | info | down) ;; *) die "internal: expected up, info, or down" ;; esac

rebuild="${SUBYARD_PROJECT_REBUILD:-0}"
project_snapshot_load
cname="subyard-box-$id"
ysecret="/srv/env-secrets/$id/profile.env"   # dev-owned, 0600, inside the yard
ymeta="/srv/env-meta/$id/profile.json"        # dev-owned, 0644, no secret values

case "$target" in
  ""|yard) die "'$name' has target=${target:-yard} — it runs in L1 (the yard), there is no L2 box. Work in the yard ('${PROG:-yard} shell $name' / '${PROG:-yard} code $name'), or re-add with --target <profile> to use a box." ;;
esac
profile="$target"
preflight

case "$sub" in
  up)
    pf="$PROFILES_DIR/$profile/profile.conf"
    [ -r "$pf" ] || die "project target '$profile' has no profile.conf at $pf"
    # profile.conf is public; profile.env is staged as a protected file.
    # shellcheck disable=SC1090
    . "$pf"
    : "${BASE_IMAGE:?profile $profile has no BASE_IMAGE}"
    sf="$PROFILES_DIR/$profile/profile.env"; have_secrets=0
    [ -r "$sf" ] && have_secrets=1

    df="${IMAGE_DOCKERFILE:-}"; run_image="$BASE_IMAGE"; ctx=""
    if [ -n "$df" ]; then
      ctx="${IMAGE_CONTEXT:-$(dirname "$df")}"
      run_image="${IMAGE_TAG:-subyard-env-$id}"
    fi

    # Never expose control sockets or agent credentials.
    for m in ${ENV_MOUNTS:-}; do
      case "${m,,}" in
        */docker.sock*|*/incus.sock*|*/lxd.sock*)
          die "ENV_MOUNTS '$m' would expose a host-control socket; Docker/Incus sockets are never mounted into a project-env" ;;
        *.claude/*|*.claude:*|*.codex/*|*.codex:*|*.pi/agent/*|*.pi/agent:*|*credentials*|*auth.json*)
          die "ENV_MOUNTS '$m' would share coding-agent credentials into the box; each project-env keeps its own credential store (sessions may be shared, creds never)" ;;
      esac
    done

    share_sessions=0
    yexec test -d "$SESSIONS_ROOT" 2>/dev/null && share_sessions=1 || true

    if ydocker inspect "$cname" >/dev/null 2>&1; then
      ydocker start "$cname" >/dev/null
      [ "$share_sessions" = 1 ] && link_box_sessions "$cname"
      ok "box '$name' already exists — started (profile $profile)"
      exit 0
    fi

    for c in ${CACHES:-}; do yexec install -d -o "$DEV_UID" -g "$DEV_UID" "$c"; done

    if [ -n "$df" ]; then
      yexec test -r "$yardPath/$df" \
        || die "profile wants '$df' in the workspace, but it's missing there — sync (or bind) the project first"
      if [ "$rebuild" = 1 ] || ! ydocker image inspect "$run_image" >/dev/null 2>&1; then
        info "building env image '$run_image' from $df (context $ctx) …"
        ydocker build -t "$run_image" -f "$yardPath/$df" "$yardPath/$ctx" || die "env image build failed"
      else
        ok "env image '$run_image' already built (use --rebuild to force)"
      fi
    fi

    # Stage secrets as a 0600 file, never Docker environment arguments.
    if [ "$have_secrets" = 1 ]; then
      yexec install -d -m 0700 -o "$DEV_UID" -g "$DEV_UID" "$(dirname "$ysecret")"
      incus file push "$sf" "$INSTANCE_NAME$ysecret" "${PROJ[@]}" \
        --mode 0600 --uid "$DEV_UID" --gid "$DEV_UID" >/dev/null \
        || die "could not stage $profile/profile.env into the yard"
    fi

    mfile="$(mktemp "${TMPDIR:-/tmp}/subyard-manifest.XXXXXX")"
    manifest_json > "$mfile"
    yexec install -d -m 0755 -o "$DEV_UID" -g "$DEV_UID" "$(dirname "$ymeta")"
    incus file push "$mfile" "$INSTANCE_NAME$ymeta" "${PROJ[@]}" \
      --mode 0644 --uid "$DEV_UID" --gid "$DEV_UID" >/dev/null \
      || { rm -f "$mfile"; die "could not stage the manifest into the yard"; }
    rm -f "$mfile"

    args=(run -d --name "$cname" --hostname "box-${name}" --restart unless-stopped
          --label subyard.env=1 --label "subyard.project=$id" --label "subyard.profile=$profile"
          -v "$yardPath:/workspace" -w /workspace)
    for c in ${CACHES:-}; do args+=(-v "$c:$c"); done
    for m in ${ENV_MOUNTS:-}; do args+=(-v "$m"); done
    [ "$share_sessions" = 1 ] && args+=(-v "$SESSIONS_ROOT:$SESSIONS_ROOT:rw")
    args+=(-v "$ymeta:/run/subyard/profile.json:ro")
    [ "$have_secrets" = 1 ] && args+=(-v "$ysecret:/run/subyard/profile.env:ro")
    # Inject public profile values only.
    while IFS= read -r k; do
      is_control_key "$k" && continue
      args+=(-e "$k=${!k}")
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$pf" | cut -d= -f1 | sort -u)
    for d in ${DEVICES:-}; do
      case "$d" in
        kvm) yexec test -e /dev/kvm && args+=(--device /dev/kvm) || warn "/dev/kvm absent in yard — skipping" ;;
        *)   warn "profile device '$d' not understood — skipping" ;;
      esac
    done
    args+=("$run_image" sleep infinity)

    info "starting box '$cname' …"
    ydocker "${args[@]}" >/dev/null || die "docker run failed in the yard"
    [ "$share_sessions" = 1 ] && link_box_sessions "$cname"
    ok "box '$name' up (profile $profile, image $run_image)"
    if [ -n "${YARD_MOUNTS:-}${YARD_CAPS:-}${YARD_DEVICES:-}" ]; then
      warn "profile '$profile' requests yard-level extras (YARD_*). Apply with: ${PROG:-yard} setup"
    fi
    cat <<MSG

Next:
  ${PROG:-yard} info $id
  ${PROG:-yard} code $id
MSG
    ;;

  info)
    ydocker inspect "$cname" >/dev/null 2>&1 || die "no box for '$name' — run: ${PROG:-yard} up $id"
    yexec test -r "$ymeta" || die "no manifest staged for '$name' — re-run: ${PROG:-yard} up $id"
    yexec cat "$ymeta"
    ;;

  down)
    ydocker inspect "$cname" >/dev/null 2>&1 || die "no box for '$name'"
    ydocker stop "$cname" >/dev/null || die "could not stop box '$name'"
    ok "box '$name' stopped"
    ;;
esac
