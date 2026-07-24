#!/usr/bin/env bash
# One-time migration from a recognized source-linked CLI to an immutable runtime.
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
  || fail "launcher does not resolve to a source checkout bin/yard"
for required in \
  "$source_root/bin/yard" \
  "$source_root/config/commands.registry" \
  "$source_root/completions/yard.bash"; do
  owned_regular "$required" || fail "source checkout file is missing or not operator-owned: $required"
done
if grep -Fq 'thin dispatcher over scripts/' "$source_launcher"; then
  :
elif grep -Fq 'Stable launcher for a release-installed native Go control-plane engine.' \
  "$source_launcher"; then
  :
else
  fail "linked checkout is not a recognized source-installed Subyard version"
fi

candidate_yard="$RUNTIME_ROOT/current/bin/yard"
candidate_engine="$RUNTIME_ROOT/current/bin/yard-engine"
[ -x "$candidate_yard" ] && [ -x "$candidate_engine" ] \
  || fail "verified candidate runtime is incomplete"
"$candidate_yard" --version >/dev/null \
  || fail "candidate runtime self-check failed"
"$candidate_yard" _migrate check >/dev/null \
  || fail "candidate rejected existing state before import"

bootstrap_paths="$("$candidate_yard" _migrate paths)" \
  || fail "candidate could not resolve bootstrap config paths"
config_home="$(jq -er '.configHome | select(type == "string" and startswith("/"))' <<<"$bootstrap_paths")" \
  || fail "candidate returned no valid config home"
case "$config_home" in "$HOME"/*) ;; *) fail "config home must stay inside the operator home" ;; esac
manifest_json="$("$candidate_yard" _migrate overlay-manifest \
  "$source_root" "$DATA_HOME" "$config_home")" \
  || fail "candidate rejected source-local runtime inputs"
jq -e --arg root "$source_root" --arg data "$DATA_HOME" --arg config "$config_home" '
  .schemaVersion == 2 and .sourceRoot == $root and
  .dataHome == $data and .configHome == $config and
  (.entries | type == "array") and
  all(.entries[];
    (.source | (type == "string") and (length > 0) and (startswith("/") | not)) and
    (.destination | (type == "string") and (length > 0) and (startswith("/") | not)) and
    (.sourceBase == "source-root" or .sourceBase == "data-home" or .sourceBase == "config-home") and
    .destinationRoot == "config-home" and
    .mode == "0600" and .conflictPolicy == "identical-or-fail")
    and all(.entries[];
      ((.contentTransform // "") == "" or
       .contentTransform == "yard-template-e2e-vms-to-test-vms"))
' <<<"$manifest_json" >/dev/null \
  || fail "candidate returned an invalid source-install manifest"

for shell_file in "$RC" "$LOGIN_RC"; do
  if [ -e "$shell_file" ] || [ -L "$shell_file" ]; then
    owned_regular "$shell_file" \
      || fail "shell rc is not an operator-owned regular file: $shell_file"
  fi
done

recovery_parent="$DATA_HOME/recovery"
recovery_root="$recovery_parent/pre-go-source"
[ ! -e "$recovery_root" ] && [ ! -L "$recovery_root" ] \
  || fail "source recovery already exists at $recovery_root"
install -d -m 0700 "$DATA_HOME" "$recovery_parent"
work="$(mktemp -d "$recovery_parent/.pre-go-source.XXXXXX")"
created="$work/created.tsv"
: > "$created"
chmod 0600 "$created"
created_directories="$work/created-directories.list"
: > "$created_directories"
chmod 0600 "$created_directories"
printf '%s\n' "$manifest_json" > "$work/source-install-manifest.json"
chmod 0600 "$work/source-install-manifest.json"
changed=0
published=0

record_created() {
  local path="$1" digest
  digest="$(sha256sum "$path" | cut -d' ' -f1)"
  printf '%s\t%s\n' "$digest" "$path" >> "$created"
}

ensure_directory() {
  local directory="$1" current mode index
  local -a missing=()
  case "$directory" in "$HOME"/*) ;; *) fail "migration directory escapes the operator home" ;; esac
  current="$directory"
  while [ ! -e "$current" ] && [ ! -L "$current" ]; do
    missing+=("$current")
    current="$(dirname "$current")"
  done
  owned_directory "$current" \
    || fail "migration parent is not an operator-owned real directory: $current"
  mode="$(stat -c '%a' -- "$current")"
  (( (8#$mode & 8#022) == 0 )) \
    || fail "migration parent is group/world writable: $current"
  for (( index=${#missing[@]}-1; index>=0; index-- )); do
    mkdir -m 0700 -- "${missing[$index]}"
    printf '%s\n' "${missing[$index]}" >> "$created_directories"
    changed=1
  done
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
  if [ -f "$created_directories" ]; then
    while IFS= read -r path; do
      [ -n "$path" ] && rmdir -- "$path" 2>/dev/null || true
    done < <(tac "$created_directories")
  fi
  state="$(<"$work/rc.state")"; path="$(<"$work/rc.path")"
  if [ "$state" = present ]; then cp -p -- "$work/rc.before" "$path"; else rm -f -- "$path"; fi
  state="$(<"$work/login-rc.state")"; path="$(<"$work/login-rc.path")"
  if [ "$state" != same ]; then
    if [ "$state" = present ]; then cp -p -- "$work/login-rc.before" "$path"; else rm -f -- "$path"; fi
  fi
  for label in legacy-data-config legacy-operator-overlay; do
    [ -f "$work/$label.state" ] || continue
    state="$(<"$work/$label.state")"
    path="$(<"$work/$label.path")"
    if [ "$state" = present ] && [ ! -e "$path" ] && [ ! -L "$path" ]; then
      mv -- "$work/$label.before" "$path"
    fi
  done
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
  local source="$1" destination="$2" mode links
  owned_regular "$source" \
    || fail "migration source is not an operator-owned regular file: $source"
  mode="$(stat -c '%a' -- "$source")"
  (( (8#$mode & 8#022) == 0 )) \
    || fail "migration source is group/world writable: $source"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    owned_regular "$destination" \
      || fail "migration target is not an operator-owned regular file: $destination"
    mode="$(stat -c '%a' -- "$destination")"
    links="$(stat -c '%h' -- "$destination")"
    [ "$mode" = 600 ] && [ "$links" = 1 ] \
      || fail "migration target has unsafe mode or link count: $destination"
    cmp -s -- "$source" "$destination" \
      || fail "migration target already exists with different content: $destination"
    return
  fi
  ensure_directory "$(dirname "$destination")"
  install -m 0600 "$source" "$destination"
  record_created "$destination"
  changed=1
}

valid_relative() {
  case "$1" in
    ''|/*|..|../*|*/..|*/../*|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
}

copy_manifest_scope() {
  local scope="$1" root="$2" source_base source destination transform source_root_path
  local install_source normalize_index=0
  while IFS=$'\t' read -r source_base source destination transform; do
    [ -n "$source" ] || continue
    valid_relative "$source" && valid_relative "$destination" \
      || fail "candidate manifest contains an unsafe path"
    case "$source_base" in
      source-root) source_root_path="$source_root" ;;
      data-home) source_root_path="$DATA_HOME" ;;
      config-home) source_root_path="$config_home" ;;
      *) fail "candidate manifest contains an unknown source base" ;;
    esac
    install_source="$source_root_path/$source"
    if [ "$transform" = "yard-template-e2e-vms-to-test-vms" ]; then
      normalize_index=$((normalize_index + 1))
      install_source="$work/normalized-yard-$normalize_index.env"
      "$candidate_yard" _migrate normalize-yard-config \
        "$source_root_path/$source" "$install_source" \
        || fail "candidate could not normalize retired yard config: $source"
    elif [ -n "$transform" ]; then
      fail "candidate manifest contains an unknown content transform"
    fi
    install_copy "$install_source" "$root/$destination"
  done < <(jq -r --arg scope "$scope" \
    '.entries[] | select(.destinationRoot == $scope) |
     [.sourceBase, .source, .destination, (.contentTransform // "")] | @tsv' \
    <<<"$manifest_json")
}

ensure_directory "$config_home"

# A materialized ledger consumer is authoritative. Legacy plaintext may be
# retained for explicit import only when it is absent or byte-identical.
while IFS=$'\t' read -r source_base source authoritative; do
  [ -n "$authoritative" ] || continue
  case "$source_base" in
    source-root) source_root_path="$source_root" ;;
    data-home) source_root_path="$DATA_HOME" ;;
    config-home) source_root_path="$config_home" ;;
    *) fail "candidate manifest contains an unknown compatibility source base" ;;
  esac
  target="$config_home/$authoritative"
  if [ -e "$target" ] || [ -L "$target" ]; then
    owned_regular "$target" && [ "$(stat -c '%a' -- "$target")" = 600 ] \
      || fail "generated credential consumer is not a protected regular file: $target"
    cmp -s -- "$source_root_path/$source" "$target" \
      || fail "legacy credential input conflicts with generated consumer: $target"
  fi
done < <(jq -r '.entries[] | select(.authoritativeDestination != null) |
  [.sourceBase, .source, .authoritativeDestination] | @tsv' <<<"$manifest_json")

copy_manifest_scope config-home "$config_home"

archive_legacy_data() {
  local path="$1" label="$2"
  printf '%s\n' "$path" > "$work/$label.path"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'absent\n' > "$work/$label.state"
    return
  fi
  if [ -d "$path" ]; then
    owned_directory "$path" || fail "legacy data input is not an operator-owned real directory: $path"
  else
    owned_regular "$path" || fail "legacy data input is not an operator-owned regular file: $path"
  fi
  mv -- "$path" "$work/$label.before"
  printf 'present\n' > "$work/$label.state"
  changed=1
}
archive_legacy_data "$DATA_HOME/config.env" legacy-data-config
archive_legacy_data "$DATA_HOME/operator-overlay" legacy-operator-overlay

paths_json="$("$candidate_yard" _migrate paths)" \
  || fail "candidate could not resolve migrated machine config"
effective_data_home="$(jq -er '.dataHome | select(type == "string" and startswith("/"))' <<<"$paths_json")" \
  || fail "candidate returned no valid data home"
[ "$effective_data_home" = "$DATA_HOME" ] \
  || fail "legacy config changes SUBYARD_HOME; rerun the installer with SUBYARD_HOME=$effective_data_home"
effective_config_home="$(jq -er '.configHome | select(type == "string" and startswith("/"))' <<<"$paths_json")" \
  || fail "candidate returned no valid config home"
[ "$effective_config_home" = "$config_home" ] \
  || fail "legacy config changes SUBYARD_CONFIG_HOME; rerun with SUBYARD_CONFIG_HOME=$effective_config_home"
printf '%s\n' "$DATA_HOME" > "$work/data-home"
printf '%s\n' "$config_home" > "$work/config-home"

mapfile -t yard_names < <(jq -r \
  '.entries[] | select(.kind == "yard-config" or .kind == "flat-yard-config") | .destination |
   split("/")[-2]' <<<"$manifest_json" | sort -u)

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

printf 'migrated source installation from %s\n' "$source_root"
printf 'one-time source recovery: %s/restore.sh\n' "$recovery_root"
