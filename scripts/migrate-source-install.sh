#!/usr/bin/env bash
# One-time migration from the historical source-linked CLI to an immutable runtime.
set -euo pipefail

RUNTIME_ROOT=''; BIN_DIR=''; RC=''; LOGIN_RC=''; DATA_HOME=''
while [ $# -gt 0 ]; do
  case "$1" in
    --runtime-root) [ $# -ge 2 ] || exit 2; RUNTIME_ROOT="$2"; shift 2 ;;
    --bin-dir) [ $# -ge 2 ] || exit 2; BIN_DIR="$2"; shift 2 ;;
    --rc) [ $# -ge 2 ] || exit 2; RC="$2"; shift 2 ;;
    --login-rc) [ $# -ge 2 ] || exit 2; LOGIN_RC="$2"; shift 2 ;;
    --data-home) [ $# -ge 2 ] || exit 2; DATA_HOME="$2"; shift 2 ;;
    *) printf 'migrate-source-install: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

fail() { printf 'migrate-source-install: %s\n' "$*" >&2; exit 1; }
for value in RUNTIME_ROOT BIN_DIR RC LOGIN_RC DATA_HOME; do
  [ -n "${!value}" ] || fail "missing --${value,,}"
  case "${!value}" in /*) ;; *) fail "$value must be absolute" ;; esac
done
for path in "$RUNTIME_ROOT" "$BIN_DIR" "$RC" "$LOGIN_RC" "$DATA_HOME"; do
  case "$path" in *$'\n'*|*$'\t'*) fail "paths containing tabs or newlines are unsupported" ;; esac
done
[ "$RUNTIME_ROOT" != / ] && [ "$BIN_DIR" != / ] && [ "$DATA_HOME" != / ] \
  || fail "refusing a filesystem-root migration path"

uid="$(id -u)"
owned_regular() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u' -- "$1")" = "$uid" ]
}
owned_directory() {
  [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u' -- "$1")" = "$uid" ]
}
owned_symlink() {
  [ -L "$1" ] && [ "$(stat -c '%u' -- "$1")" = "$uid" ]
}

yard_link="$BIN_DIR/yard"
sy_link="$BIN_DIR/sy"
if [ ! -e "$yard_link" ] && [ ! -L "$yard_link" ] &&
   [ ! -e "$sy_link" ] && [ ! -L "$sy_link" ]; then
  exit 3
fi
owned_symlink "$yard_link" && owned_symlink "$sy_link" \
  || fail "yard and sy must both be operator-owned symbolic links"
yard_target="$(readlink -f -- "$yard_link")" || fail "cannot resolve the yard link"
sy_target="$(readlink -f -- "$sy_link")" || fail "cannot resolve the sy link"
[ "$yard_target" = "$sy_target" ] || fail "yard and sy point to different installations"
case "$yard_target" in "$RUNTIME_ROOT"/*) exit 3 ;; esac
case "$BIN_DIR" in "$HOME"/*) ;; *) fail "launcher directory must be inside the operator home" ;; esac
case "$RC" in "$HOME"/*) ;; *) fail "interactive shell rc must be inside the operator home" ;; esac
case "$LOGIN_RC" in "$HOME"/*) ;; *) fail "login shell rc must be inside the operator home" ;; esac
case "$DATA_HOME" in "$HOME"/*) ;; *) fail "Subyard data home must be inside the operator home" ;; esac

source_launcher="$yard_target"
source_root="$(cd "$(dirname "$source_launcher")/.." && pwd -P)"
[ "$source_launcher" = "$source_root/bin/yard" ] \
  || fail "legacy launcher does not resolve to a source checkout bin/yard"
for required in \
  "$source_root/bin/yard" \
  "$source_root/scripts/install-cli.sh" \
  "$source_root/config/commands.registry" \
  "$source_root/completions/yard.bash"; do
  owned_regular "$required" || fail "legacy checkout file is missing or not operator-owned: $required"
done
grep -Fq 'thin dispatcher over scripts/' "$source_launcher" \
  || fail "linked checkout is not a recognized pre-Go Subyard installation"

candidate_yard="$RUNTIME_ROOT/current/bin/yard"
candidate_engine="$RUNTIME_ROOT/current/bin/yard-engine"
[ -x "$candidate_yard" ] && [ -x "$candidate_engine" ] \
  || fail "verified candidate runtime is incomplete"
"$candidate_yard" --version >/dev/null \
  || fail "candidate runtime self-check failed"
"$candidate_yard" _migrate check >/dev/null \
  || fail "candidate rejected existing state before import"

for shell_file in "$RC" "$LOGIN_RC"; do
  if [ -e "$shell_file" ] || [ -L "$shell_file" ]; then
    owned_regular "$shell_file" \
      || fail "shell rc is not an operator-owned regular file: $shell_file"
  fi
done

legacy_private="$source_root/private"
legacy_config="$legacy_private/config.env"
legacy_yards="$legacy_private/yards"
legacy_agents="$legacy_private/agents"
if [ -e "$legacy_config" ] || [ -L "$legacy_config" ]; then
  owned_regular "$legacy_config" \
    || fail "legacy private/config.env is not an operator-owned regular file"
fi
if [ -e "$legacy_yards" ] || [ -L "$legacy_yards" ]; then
  owned_directory "$legacy_yards" \
    || fail "legacy private/yards is not an operator-owned directory"
  [ -z "$(find "$legacy_yards" -mindepth 1 \( -type l -o ! -type f \) -print -quit)" ] \
    || fail "legacy private/yards contains a symlink or non-regular entry"
fi
if [ -e "$legacy_agents" ] || [ -L "$legacy_agents" ]; then
  owned_directory "$legacy_agents" \
    || fail "legacy private/agents is not an operator-owned directory"
  [ -z "$(find "$legacy_agents" -mindepth 1 \( -type l -o \( ! -type f ! -type d \) \) -print -quit)" ] \
    || fail "legacy private/agents contains a symlink or special entry"
  [ -z "$(find "$legacy_agents" -mindepth 1 ! -uid "$uid" -print -quit)" ] \
    || fail "legacy private/agents contains an entry owned by another user"
fi

recovery_parent="$DATA_HOME/recovery"
recovery_root="$recovery_parent/pre-go-source"
[ ! -e "$recovery_root" ] && [ ! -L "$recovery_root" ] \
  || fail "source recovery already exists at $recovery_root"
install -d -m 0700 "$DATA_HOME" "$recovery_parent"
work="$(mktemp -d "$recovery_parent/.pre-go-source.XXXXXX")"
created="$work/created.tsv"
: > "$created"
chmod 0600 "$created"
changed=0
published=0

record_created() {
  local path="$1" digest
  digest="$(sha256sum "$path" | cut -d' ' -f1)"
  printf '%s\t%s\n' "$digest" "$path" >> "$created"
}

backup_shell_file() {
  local path="$1" label="$2"
  printf '%s\n' "$path" > "$work/$label.path"
  if [ -e "$path" ]; then
    cp -p -- "$path" "$work/$label.before"
    printf 'present\n' > "$work/$label.state"
  else
    printf 'absent\n' > "$work/$label.state"
  fi
}
backup_shell_file "$RC" rc
if [ "$LOGIN_RC" = "$RC" ]; then
  printf 'same\n' > "$work/login-rc.state"
  printf '%s\n' "$LOGIN_RC" > "$work/login-rc.path"
else
  backup_shell_file "$LOGIN_RC" login-rc
fi
printf '%s\n' "$(readlink "$yard_link")" > "$work/yard.target"
printf '%s\n' "$(readlink "$sy_link")" > "$work/sy.target"
printf '%s\n' "$BIN_DIR" > "$work/bin-dir"
printf '%s\n' "$RUNTIME_ROOT/current/bin/yard" > "$work/runtime-launcher"

restore_partial() {
  local state path
  [ "$changed" = 1 ] || return 0
  while IFS=$'\t' read -r _ path; do
    [ -n "$path" ] && rm -f -- "$path"
  done < "$created"
  state="$(<"$work/rc.state")"; path="$(<"$work/rc.path")"
  if [ "$state" = present ]; then cp -p -- "$work/rc.before" "$path"; else rm -f -- "$path"; fi
  state="$(<"$work/login-rc.state")"; path="$(<"$work/login-rc.path")"
  if [ "$state" != same ]; then
    if [ "$state" = present ]; then cp -p -- "$work/login-rc.before" "$path"; else rm -f -- "$path"; fi
  fi
  ln -sfn -- "$(<"$work/yard.target")" "$yard_link"
  ln -sfn -- "$(<"$work/sy.target")" "$sy_link"
}
cleanup() {
  status=$?
  if [ "$status" -ne 0 ] && [ "$published" = 0 ]; then restore_partial; fi
  [ "$published" = 1 ] || rm -rf -- "$work"
  exit "$status"
}
trap cleanup EXIT

install_copy() {
  local source="$1" destination="$2"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    owned_regular "$destination" \
      || fail "migration target is not an operator-owned regular file: $destination"
    cmp -s -- "$source" "$destination" \
      || fail "migration target already exists with different content: $destination"
    return
  fi
  install -d -m 0700 "$(dirname "$destination")"
  install -m 0600 "$source" "$destination"
  record_created "$destination"
  changed=1
}

machine_config="$DATA_HOME/config.env"
if [ -e "$legacy_config" ]; then
  install_copy "$legacy_config" "$machine_config"
fi
overlay_private="$DATA_HOME/operator-overlay/private"
if [ -d "$legacy_agents" ]; then
  if [ -e "$overlay_private/agents" ] || [ -L "$overlay_private/agents" ]; then
    owned_directory "$overlay_private/agents" \
      && diff -qr -- "$legacy_agents" "$overlay_private/agents" >/dev/null \
      || fail "migrated private agent overlay already exists with different content"
  else
    install -d -m 0700 "$overlay_private"
    cp -a -- "$legacy_agents" "$overlay_private/agents"
    while IFS= read -r file; do record_created "$file"; done \
      < <(find "$overlay_private/agents" -type f -print)
    changed=1
  fi
fi

paths_json="$("$candidate_yard" _migrate paths)" \
  || fail "candidate could not resolve migrated machine config"
effective_data_home="$(jq -er '.dataHome | select(type == "string" and startswith("/"))' <<<"$paths_json")" \
  || fail "candidate returned no valid data home"
[ "$effective_data_home" = "$DATA_HOME" ] \
  || fail "legacy config changes SUBYARD_HOME; rerun the installer with SUBYARD_HOME=$effective_data_home"
config_home="$(jq -er '.configHome | select(type == "string" and startswith("/"))' <<<"$paths_json")" \
  || fail "candidate returned no valid config home"
case "$config_home" in "$HOME"/*) ;; *) fail "migrated config home must stay inside the operator home" ;; esac
printf '%s\n' "$DATA_HOME" > "$work/data-home"
printf '%s\n' "$config_home" > "$work/config-home"

declare -a yard_names=()
if [ -d "$legacy_yards" ]; then
  for source in "$legacy_yards"/*.env; do
    [ -e "$source" ] || continue
    name="$(basename "$source" .env)"
    case "$name" in ''|*[!a-z0-9_-]*|[-_]*) fail "unsafe legacy yard name: $name" ;; esac
    install_copy "$source" "$config_home/yards/$name.env"
    yard_names+=("$name")
  done
fi

"$candidate_yard" _migrate apply >/dev/null \
  || fail "candidate could not migrate default and registered state"
for name in "${yard_names[@]}"; do
  "$candidate_yard" -Y "$name" _migrate apply >/dev/null \
    || fail "candidate could not migrate yard $name"
  "$candidate_yard" -Y "$name" _migrate check >/dev/null \
    || fail "candidate rejected migrated yard $name"
done

rewrite_completion() {
  local path="$1" output="$2" line next marker=0
  local old_bash="[ -f \"$source_root/completions/yard.bash\" ] && source \"$source_root/completions/yard.bash\""
  local old_zsh="[ -f \"$source_root/completions/yard.zsh\" ] && source \"$source_root/completions/yard.zsh\""
  local completion="$RUNTIME_ROOT/current/completions/yard.bash"
  case "$path" in *zsh*) completion="$RUNTIME_ROOT/current/completions/yard.zsh" ;; esac
  local replacement="[ -f \"$completion\" ] && source \"$completion\""
  : > "$output"
  if [ -e "$path" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$line" = '# Subyard CLI completion' ]; then
        [ "$marker" = 0 ] || fail "duplicate Subyard completion marker in $path"
        marker=1
        IFS= read -r next || next=''
        case "$next" in
          "$old_bash"|"$old_zsh"|"$replacement") ;;
          *) fail "unrecognized Subyard completion block in $path" ;;
        esac
        printf '%s\n%s\n' "$line" "$replacement" >> "$output"
      else
        printf '%s\n' "$line" >> "$output"
      fi
    done < "$path"
  fi
  if [ "$marker" = 0 ]; then
    printf '\n# Subyard CLI completion\n%s\n' "$replacement" >> "$output"
  fi
}

rewrite_completion "$RC" "$work/rc.after"
chmod --reference="${RC:-$work/rc.after}" "$work/rc.after" 2>/dev/null || chmod 0600 "$work/rc.after"
if ! grep -qF 'Subyard CLI login PATH' "$LOGIN_RC" 2>/dev/null; then
  if [ "$LOGIN_RC" = "$RC" ]; then
    printf '\n# Subyard CLI login PATH\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$work/rc.after"
  else
    if [ -e "$LOGIN_RC" ]; then cp -p -- "$LOGIN_RC" "$work/login-rc.after"; else : > "$work/login-rc.after"; fi
    printf '\n# Subyard CLI login PATH\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$work/login-rc.after"
  fi
elif [ "$LOGIN_RC" != "$RC" ]; then
  cp -p -- "$LOGIN_RC" "$work/login-rc.after"
fi
if [ "$LOGIN_RC" != "$RC" ]; then
  chmod --reference="${LOGIN_RC:-$work/login-rc.after}" "$work/login-rc.after" 2>/dev/null \
    || chmod 0600 "$work/login-rc.after"
fi

changed=1
install -m "$(stat -c '%a' "$work/rc.after")" "$work/rc.after" "$RC"
if [ "$LOGIN_RC" != "$RC" ]; then
  install -m "$(stat -c '%a' "$work/login-rc.after")" "$work/login-rc.after" "$LOGIN_RC"
fi
ln -sfn -- "$RUNTIME_ROOT/current/bin/yard" "$yard_link"
ln -sfn -- "$RUNTIME_ROOT/current/bin/yard" "$sy_link"

sha256sum "$RC" | cut -d' ' -f1 > "$work/rc.after.sha256"
if [ "$LOGIN_RC" = "$RC" ]; then
  cp "$work/rc.after.sha256" "$work/login-rc.after.sha256"
else
  sha256sum "$LOGIN_RC" | cut -d' ' -f1 > "$work/login-rc.after.sha256"
fi
install -m 0700 "$(dirname "$0")/restore-source-install.sh" "$work/restore.sh"
printf '%s\n' "$source_root" > "$work/source-root"
chmod 0700 "$work/restore.sh"
mv "$work" "$recovery_root"
published=1
trap - EXIT

printf 'migrated pre-Go source installation from %s\n' "$source_root"
printf 'one-time source recovery: %s/restore.sh\n' "$recovery_root"
