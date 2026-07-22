#!/usr/bin/env bash
# registry.sh — pure yard-registry paths, lookup and context derivation.

[ -n "${SUBYARD_REGISTRY_SOURCED:-}" ] && return 0
SUBYARD_REGISTRY_SOURCED=1

yard_registry_dirs() {
  : "${SUBYARD_OPERATOR_HOME:=$(subyard_operator_home)}"
  printf '%s\n' "$SUBYARD_CONFIG_DIR/../private/yards"
  printf '%s\n' "${SUBYARD_CONFIG_HOME:-$SUBYARD_OPERATOR_HOME/.config/subyard}/yards"
}

yard_env_file() {
  local name="${1:?yard_env_file needs a name}" dir
  while IFS= read -r dir; do
    [ -r "$dir/$name.env" ] && { printf '%s\n' "$dir/$name.env"; return 0; }
  done < <(yard_registry_dirs)
  return 1
}

yard_template_file() { # <yard-env-file>; empty when no public template is selected
  local file="${1:?yard_template_file needs a yard env file}" template path
  template="$(yard_env_val "$file" YARD_TEMPLATE)"
  [ -n "$template" ] || return 1
  yard_valid_name "$template" || die "invalid YARD_TEMPLATE '$template' in $file"
  path="$SUBYARD_CONFIG_DIR/yards/profiles/$template.env"
  [ -r "$path" ] || die "unknown YARD_TEMPLATE '$template' in $file"
  printf '%s\n' "$path"
}

yard_source_env() { # <yard-name>; public template first, selected machine/operator file second
  local name="${1:?yard_source_env needs a name}" file template_file=''
  file="$(yard_env_file "$name")" || return 1
  template_file="$(yard_template_file "$file" 2>/dev/null || true)"
  if [ -n "$template_file" ]; then
    # shellcheck disable=SC1090
    . "$template_file"
  elif [ -n "$(yard_env_val "$file" YARD_TEMPLATE)" ]; then
    # Re-run without stderr suppression to report the invalid/missing template.
    yard_template_file "$file" >/dev/null
  fi
  # shellcheck disable=SC1090
  . "$file"
}

yard_registry_names() {
  local dir file
  {
    printf 'default\n'
    while IFS= read -r dir; do
      [ -d "$dir" ] || continue
      for file in "$dir"/*.env; do
        [ -e "$file" ] || continue
        basename "$file" .env
      done
    done < <(yard_registry_dirs)
  } | awk 'NF && !seen[$0]++'
}

yard_valid_name() {
  case "$1" in '' | *[!a-z0-9_-]*) return 1 ;; [a-z0-9]*) return 0 ;; *) return 1 ;; esac
}

yard_apply_derivations() {
  local name="$1" config_home="${SUBYARD_CONFIG_HOME:-$SUBYARD_OPERATOR_HOME/.config/subyard}"
  YARD_NAME="$name"
  : "${INSTANCE_NAME:=yard-$name}"
  : "${INCUS_PROJECT:=subyard-$name}"
  : "${SSH_HOST:=yard-$name}"
  : "${SRV_VOLUME:=yard-srv-$name}"
  : "${RESTRICTED_DISK_PATHS:=/srv/subyard-$name}"
  : "${SUBYARD_STATE_DIR:=$config_home/yards/$name/projects}"
}

yard_context_select() {
  local name="${SUBYARD_YARD:-}" file
  case "$name" in '' | default) return 0 ;; esac
  yard_valid_name "$name" \
    || die "invalid yard name '$name' (allowed: lowercase letters, digits, '-', '_'; must start with a letter or digit)"
  file="$(yard_env_file "$name")" \
    || die "unknown yard '$name' — known yards: $(yard_registry_names | tr '\n' ' ')"
  yard_source_env "$name"
  yard_apply_derivations "$name"
  if [ "${YARD_TYPE:-local}" != remote ] && [ -z "${SSH_PORT:-}" ]; then
    die "yard '$name' ($file) sets no SSH_PORT — a local yard needs a unique host loopback port (add e.g. SSH_PORT=2223)"
  fi
}

yard_cmd_hint() {
  printf '%s' "${PROG:-yard}"
  [ -n "${YARD_NAME:-}" ] && printf ' -Y %s' "$YARD_NAME"
  return 0
}
