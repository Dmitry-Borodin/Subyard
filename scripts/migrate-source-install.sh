#!/usr/bin/env bash
# One-time migration from a recognized pre-0.1 source-linked CLI to an immutable runtime.
# Removal requires a separate compatibility review no earlier than 2026-10-24.
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
case "$DATA_HOME" in "$HOME"/*) ;; *) fail "Subyard data home must be inside the operator home" ;; esac

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
command -v sync >/dev/null 2>&1 || fail "sync is required for durable source migration"
persist() {
  sync -f -- "$1" || fail "could not persist source migration state: $1"
}
persist_file() {
  sync -d -- "$1" || fail "could not persist source migration file: $1"
}

recovery_parent="$DATA_HOME/recovery"
recovery_root="$recovery_parent/pre-go-source"
read_transaction() {
  local transaction="$1" key value
  transaction_schema=''; transaction_phase=''; transaction_step=''
  owned_regular "$transaction" && [ "$(stat -c '%a' -- "$transaction")" = 600 ] \
    || fail "source recovery transaction is missing or unsafe"
  while IFS='=' read -r key value; do
    case "$key" in
      schema) [ -z "$transaction_schema" ] || fail "duplicate recovery transaction schema"
        transaction_schema="$value" ;;
      phase) [ -z "$transaction_phase" ] || fail "duplicate recovery transaction phase"
        transaction_phase="$value" ;;
      step) [ -z "$transaction_step" ] || fail "duplicate recovery transaction step"
        transaction_step="$value" ;;
      *) fail "unknown recovery transaction field" ;;
    esac
  done < "$transaction"
  [ "$transaction_schema" = 1 ] && [ -n "$transaction_phase" ] && [ -n "$transaction_step" ] \
    || fail "source recovery transaction is incomplete"
  case "$transaction_phase:$transaction_step" in
    prepared:none|applying:config-import|applying:legacy-archive|applying:state-migration|\
applying:shell-integration|applying:entrypoint-switch|complete:complete) ;;
    *) fail "invalid source recovery transaction phase/step" ;;
  esac
}

if [ -e "$recovery_root" ] || [ -L "$recovery_root" ]; then
  owned_directory "$recovery_root" \
    || fail "source recovery is not an operator-owned real directory: $recovery_root"
  if [ -e "$recovery_root/transaction" ] || [ -L "$recovery_root/transaction" ]; then
    read_transaction "$recovery_root/transaction"
    case "$transaction_phase" in
      prepared|applying)
        owned_regular "$recovery_root/restore.sh" && [ -x "$recovery_root/restore.sh" ] \
          || fail "incomplete source recovery has no trusted restore entrypoint"
        "$recovery_root/restore.sh" --recovery-root "$recovery_root" --incomplete \
          || fail "incomplete source migration requires operator recovery at $recovery_root"
        printf 'migrate-source-install: recovered incomplete source migration; retrying\n' >&2
        ;;
      complete) ;;
      *) fail "unknown source recovery transaction phase: $transaction_phase" ;;
    esac
  fi
fi

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
case "$config_home" in *$'\n'*|*$'\t'*) fail "candidate returned an unsafe config home" ;; esac
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

[ ! -e "$recovery_root" ] && [ ! -L "$recovery_root" ] \
  || fail "source recovery already exists at $recovery_root"
install -d -m 0700 "$DATA_HOME" "$recovery_parent"
work="$(mktemp -d "$recovery_parent/.pre-go-source.XXXXXX")"
published=0
cleanup() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    if [ "$published" = 1 ]; then
      if ! "$recovery_root/restore.sh" --recovery-root "$recovery_root" --incomplete; then
        printf 'migrate-source-install: automatic recovery failed; journal retained at %s\n' \
          "$recovery_root" >&2
      fi
    else
      rm -rf -- "$work"
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

created="$work/created.tsv"
created_directories="$work/created-directories.list"
temporary_files="$work/temporary-files.tsv"
for record in "$created" "$created_directories" "$temporary_files"; do
  : > "$record"
  chmod 0600 "$record"
done
printf '%s\n' "$manifest_json" > "$work/source-install-manifest.json"
chmod 0600 "$work/source-install-manifest.json"

write_value() {
  printf '%s\n' "$2" > "$work/$1"
  chmod 0600 "$work/$1"
}
backup_shell_file() {
  local path="$1" label="$2"
  write_value "$label.path" "$path"
  if [ -e "$path" ]; then
    cp -p -- "$path" "$work/$label.before"
    write_value "$label.state" present
  else
    write_value "$label.state" absent
  fi
}
backup_shell_file "$RC" rc
if [ "$LOGIN_RC" = "$RC" ]; then
  write_value login-rc.state same
  write_value login-rc.path "$LOGIN_RC"
else
  backup_shell_file "$LOGIN_RC" login-rc
fi
write_value yard.target "$(readlink "$yard_link")"
write_value sy.target "$(readlink "$sy_link")"
write_value bin-dir "$BIN_DIR"
write_value runtime-launcher "$RUNTIME_ROOT/current/bin/yard"
write_value data-home "$DATA_HOME"
write_value config-home "$config_home"
write_value source-root "$source_root"

prepare_legacy_data() {
  local path="$1" label="$2"
  write_value "$label.path" "$path"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    write_value "$label.state" absent
    return
  fi
  if [ -d "$path" ]; then
    owned_directory "$path" || fail "legacy data input is not an operator-owned real directory: $path"
  else
    owned_regular "$path" || fail "legacy data input is not an operator-owned regular file: $path"
  fi
  write_value "$label.state" present
}
prepare_legacy_data "$DATA_HOME/config.env" legacy-data-config
prepare_legacy_data "$DATA_HOME/operator-overlay" legacy-operator-overlay

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
sha256sum "$work/rc.after" | cut -d' ' -f1 > "$work/rc.after.sha256"
if [ "$LOGIN_RC" = "$RC" ]; then
  cp "$work/rc.after.sha256" "$work/login-rc.after.sha256"
else
  sha256sum "$work/login-rc.after" | cut -d' ' -f1 > "$work/login-rc.after.sha256"
fi
chmod 0600 "$work/rc.after.sha256" "$work/login-rc.after.sha256"

rc_temp="$RC.subyard-migrate.$$"
login_rc_temp="$LOGIN_RC.subyard-migrate.$$"
yard_temp="$BIN_DIR/.yard.subyard-migrate.$$"
sy_temp="$BIN_DIR/.sy.subyard-migrate.$$"
write_value rc.temp "$rc_temp"
write_value login-rc.temp "$login_rc_temp"
write_value yard.temp "$yard_temp"
write_value sy.temp "$sy_temp"
for path in "$rc_temp" "$yard_temp" "$sy_temp"; do
  [ ! -e "$path" ] && [ ! -L "$path" ] || fail "migration temporary path already exists: $path"
done
if [ "$LOGIN_RC" != "$RC" ]; then
  [ ! -e "$login_rc_temp" ] && [ ! -L "$login_rc_temp" ] \
    || fail "migration temporary path already exists: $login_rc_temp"
fi

install -m 0700 "$(dirname "$0")/restore-source-install.sh" "$work/restore.sh"
write_transaction() {
  local phase="$1" step="$2" temporary="$work/.transaction.tmp.$$"
  {
    printf 'schema=1\n'
    printf 'phase=%s\n' "$phase"
    printf 'step=%s\n' "$step"
  } > "$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$work/transaction"
  persist "$work"
}
write_transaction prepared none
chmod 0700 "$work/restore.sh"
mv -- "$work" "$recovery_root"
work="$recovery_root"
created="$work/created.tsv"
created_directories="$work/created-directories.list"
temporary_files="$work/temporary-files.tsv"
published=1
persist "$recovery_parent"

append_record() {
  local record="$1" line="$2" temporary
  temporary="$work/.$(basename "$record").tmp.$$"
  cp -- "$record" "$temporary"
  printf '%s\n' "$line" >> "$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$record"
}
record_created() {
  local source="$1" path="$2" digest
  digest="$(sha256sum "$source" | cut -d' ' -f1)"
  append_record "$created" "$digest"$'\t'"$path"
}
record_temporary_file() {
  local source="$1" path="$2" digest
  digest="$(sha256sum "$source" | cut -d' ' -f1)"
  append_record "$temporary_files" "$digest"$'\t'"$path"
}
record_directory() {
  if ! grep -Fxq -- "$1" "$created_directories"; then
    append_record "$created_directories" "$1"
    persist "$work"
  fi
}
fault_after() {
  [ "${SUBYARD_SOURCE_MIGRATION_FAULT_AFTER:-}" != "$1" ] || {
    printf 'migrate-source-install: fault injection after %s\n' "$1" >&2
    kill -KILL "$$"
  }
}
fault_after prepared

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
    record_directory "${missing[$index]}"
    if [ ! -e "${missing[$index]}" ] && [ ! -L "${missing[$index]}" ]; then
      mkdir -m 0700 -- "${missing[$index]}"
    fi
    owned_directory "${missing[$index]}" \
      || fail "migration directory is not an operator-owned real directory: ${missing[$index]}"
  done
}

install_copy() {
  local source="$1" destination="$2" mode links temporary
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
  temporary="$destination.subyard-migrate.$$"
  [ ! -e "$temporary" ] && [ ! -L "$temporary" ] \
    || fail "migration temporary path already exists: $temporary"
  record_created "$source" "$destination"
  record_temporary_file "$source" "$temporary"
  persist "$work"
  install -m 0600 "$source" "$temporary"
  persist_file "$temporary"
  fault_after config-import-temporary
  mv -fT -- "$temporary" "$destination"
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

write_transaction applying config-import
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
persist "$config_home"
fault_after config-import

archive_legacy_data() {
  local path="$1" label="$2" state
  state="$(<"$work/$label.state")"
  [ "$state" = present ] || return 0
  [ -e "$path" ] || [ -L "$path" ] \
    || fail "legacy data input disappeared before archival: $path"
  [ ! -e "$work/$label.before" ] && [ ! -L "$work/$label.before" ] \
    || fail "legacy recovery payload already exists: $label"
  if [ -d "$path" ]; then
    owned_directory "$path" || fail "legacy data input is not an operator-owned real directory: $path"
  else
    owned_regular "$path" || fail "legacy data input is not an operator-owned regular file: $path"
  fi
  mv -- "$path" "$work/$label.before"
}

write_transaction applying legacy-archive
archive_legacy_data "$DATA_HOME/config.env" legacy-data-config
archive_legacy_data "$DATA_HOME/operator-overlay" legacy-operator-overlay
persist "$work"
fault_after legacy-archive

paths_json="$("$candidate_yard" _migrate paths)" \
  || fail "candidate could not resolve migrated host settings"
effective_data_home="$(jq -er '.dataHome | select(type == "string" and startswith("/"))' <<<"$paths_json")" \
  || fail "candidate returned no valid data home"
[ "$effective_data_home" = "$DATA_HOME" ] \
  || fail "legacy config changes SUBYARD_HOME; rerun the installer with SUBYARD_HOME=$effective_data_home"
effective_config_home="$(jq -er '.configHome | select(type == "string" and startswith("/"))' <<<"$paths_json")" \
  || fail "candidate returned no valid config home"
[ "$effective_config_home" = "$config_home" ] \
  || fail "legacy config changes SUBYARD_CONFIG_HOME; rerun with SUBYARD_CONFIG_HOME=$effective_config_home"

mapfile -t yard_names < <(jq -r \
  '.entries[] | select(.kind == "yard-config" or .kind == "flat-yard-config") | .destination |
   split("/")[-2]' <<<"$manifest_json" | sort -u)
mapfile -t project_directories < <(jq -r '.projectDirectories[]?' <<<"$paths_json")
for directory in "${project_directories[@]}"; do
  case "$directory" in /*) ;; *) fail "candidate returned an invalid project state directory" ;; esac
  case "$directory" in *$'\n'*|*$'\t'*) fail "candidate returned an unsafe project state directory" ;; esac
done

write_transaction applying state-migration
"$candidate_yard" _migrate apply >/dev/null \
  || fail "candidate could not migrate default and registered state"
for name in "${yard_names[@]}"; do
  "$candidate_yard" -Y "$name" _migrate apply >/dev/null \
    || fail "candidate could not migrate yard $name"
  "$candidate_yard" -Y "$name" _migrate check >/dev/null \
    || fail "candidate rejected migrated yard $name"
done
persist "$config_home"
for directory in "${project_directories[@]}"; do
  [ ! -d "$directory" ] || persist "$directory"
done
fault_after state-migration

atomic_install() {
  local source="$1" destination="$2" temporary="$3" mode
  mode="$(stat -c '%a' -- "$source")"
  [ ! -e "$temporary" ] && [ ! -L "$temporary" ] \
    || fail "migration temporary path appeared during apply: $temporary"
  install -m "$mode" "$source" "$temporary"
  persist_file "$temporary"
  fault_after shell-integration-temporary
  mv -fT -- "$temporary" "$destination"
  persist "$(dirname "$destination")"
}

write_transaction applying shell-integration
atomic_install "$work/rc.after" "$RC" "$rc_temp"
fault_after shell-integration-rc
if [ "$LOGIN_RC" != "$RC" ]; then
  atomic_install "$work/login-rc.after" "$LOGIN_RC" "$login_rc_temp"
fi
fault_after shell-integration

atomic_link() {
  local target="$1" destination="$2" temporary="$3"
  [ ! -e "$temporary" ] && [ ! -L "$temporary" ] \
    || fail "migration temporary link appeared during apply: $temporary"
  ln -s -- "$target" "$temporary"
  fault_after entrypoint-switch-temporary
  mv -fT -- "$temporary" "$destination"
  persist "$(dirname "$destination")"
}

write_transaction applying entrypoint-switch
atomic_link "$RUNTIME_ROOT/current/bin/yard" "$sy_link" "$sy_temp"
fault_after entrypoint-switch-sy
atomic_link "$RUNTIME_ROOT/current/bin/yard" "$yard_link" "$yard_temp"
fault_after entrypoint-switch

write_transaction complete complete
trap - EXIT

printf 'migrated source installation from %s\n' "$source_root"
printf 'one-time source recovery: %s/restore.sh\n' "$recovery_root"
