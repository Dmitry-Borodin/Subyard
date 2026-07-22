#!/usr/bin/env bash
# install-cli.sh — install a verified runtime and link its stable `yard`/`sy` entrypoint.
# Operator, no sudo. A child can't change the current shell's PATH — it prints the
# one activation command. Env: YARD_BIN_DIR, YARD_SHELL_RC, YARD_LOGIN_RC; flag -y.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Explicit control-plane module composition (config/context loads exactly once).
# shellcheck source=scripts/lib/runtime.sh
. "$SCRIPT_DIR/lib/runtime.sh"
# shellcheck source=scripts/lib/env.sh
. "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=scripts/lib/registry.sh
. "$SCRIPT_DIR/lib/registry.sh"
# shellcheck source=scripts/lib/context.sh
. "$SCRIPT_DIR/lib/context.sh"
# shellcheck source=scripts/lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=scripts/lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"
subyard_context_load

REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_LAUNCHER="$REPO/bin/yard"
RUNTIME_ROOT="${YARD_RUNTIME_ROOT:-$SUBYARD_HOME/runtime}"
YARD_SRC="$RUNTIME_ROOT/current/bin/yard"
YARD_ENGINE="$RUNTIME_ROOT/current/bin/yard-engine"
BIN_DIR="${YARD_BIN_DIR:-$HOME/.local/bin}"

[ -x "$SOURCE_LAUNCHER" ] || die "yard installer launcher not found at $SOURCE_LAUNCHER"

# Is BIN_DIR already on PATH?
need_path_line=1
case ":$PATH:" in *":$BIN_DIR:"*) need_path_line=0 ;; esac

# Pick an rc file only if we need to add to PATH.
RC="${YARD_SHELL_RC:-}"
if [ -z "$RC" ]; then
  case "${SHELL:-}" in
    *zsh) RC="$HOME/.zshrc" ;;
    *)    RC="$HOME/.bashrc" ;;
  esac
fi

# Remote-owner control calls use a login shell. Configure the first Bash login file that Bash will
# actually read instead of assuming that a distribution-specific .profile sources .bashrc.
LOGIN_RC="${YARD_LOGIN_RC:-}"
if [ -z "$LOGIN_RC" ]; then
  case "${SHELL:-}" in
    *zsh) LOGIN_RC="$HOME/.zprofile" ;;
    *)
      if [ -f "$HOME/.bash_profile" ]; then LOGIN_RC="$HOME/.bash_profile"
      elif [ -f "$HOME/.bash_login" ]; then LOGIN_RC="$HOME/.bash_login"
      else LOGIN_RC="$HOME/.profile"
      fi
      ;;
  esac
fi

# Shell-appropriate completion file to source from the rc.
case "$RC" in
  *zsh*) COMP="$RUNTIME_ROOT/current/completions/yard.zsh" ;;
  *)     COMP="$RUNTIME_ROOT/current/completions/yard.bash" ;;
esac

lines=("Install a checksum/provenance-verified release runtime at $RUNTIME_ROOT.")
lines+=("Symlink: $BIN_DIR/yard and $BIN_DIR/sy → $YARD_SRC")
lines+=("Ensure login shells include $BIN_DIR via $LOGIN_RC.")
if [ "$need_path_line" = 1 ]; then
  lines+=("Add $BIN_DIR to PATH via $RC (it is not on PATH yet).")
else
  lines+=("$BIN_DIR is already on PATH — no shell rc change.")
fi
lines+=("Enable tab-completion by sourcing $COMP from $RC.")
announce "Install the yard CLI" "${lines[@]}"
proceed_or_die

if [ ! -x "$YARD_SRC" ] || [ ! -x "$YARD_ENGINE" ]; then
  update_args=(--runtime-root "$RUNTIME_ROOT")
  [ -z "${YARD_RELEASE_VERSION:-}" ] || update_args+=(--version "$YARD_RELEASE_VERSION")
  [ "${YARD_RELEASE_OFFLINE:-0}" != 1 ] || update_args+=(--offline)
  "$SCRIPT_DIR/bootstrap-runtime.sh" "${update_args[@]}" \
    || die "release runtime installation failed; launcher links were not changed"
fi
[ -x "$YARD_SRC" ] && [ -x "$YARD_ENGINE" ] \
  || die "installed release runtime is incomplete"

install -d "$BIN_DIR"
ln -sf "$YARD_SRC" "$BIN_DIR/yard"
ln -sf "$YARD_SRC" "$BIN_DIR/sy"
ok "linked $BIN_DIR/{yard,sy} → release runtime $YARD_SRC"

if [ -f "$LOGIN_RC" ] && grep -qF 'Subyard CLI login PATH' "$LOGIN_RC"; then
  ok "login PATH line already present in $LOGIN_RC"
else
  printf '\n# Subyard CLI login PATH\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$LOGIN_RC"
  ok "added $BIN_DIR to login-shell PATH in $LOGIN_RC"
fi

if [ "$need_path_line" = 1 ]; then
  if [ -f "$RC" ] && grep -qF 'Subyard CLI' "$RC"; then
    ok "PATH line already present in $RC"
  else
    printf '\n# Subyard CLI\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$RC"
    ok "added $BIN_DIR to PATH in $RC"
  fi
fi

# Tab-completion: source the completion file from the rc (idempotent via marker).
if [ -f "$RC" ] && grep -qF 'Subyard CLI completion' "$RC"; then
  ok "completion already wired in $RC"
else
  printf '\n# Subyard CLI completion\n[ -f "%s" ] && source "%s"\n' "$COMP" "$COMP" >> "$RC"
  ok "wired tab-completion into $RC"
fi

# --- summary -----------------------------------------------------------------
echo
ok "yard CLI installed."
if [ "$need_path_line" = 1 ]; then
  cat <<MSG

Activate it in THIS shell (a script can't change your current shell's PATH):
  exec "\$SHELL" -l        # or:  source $RC
New shells pick it up automatically (incl. tab-completion). Then try:  yard help
MSG
else
  cat <<MSG

Ready — try:  yard help
Tab-completion activates in new shells, or now with:  source $COMP
(if 'yard' is not found yet in this shell, run: hash -r)
MSG
fi
