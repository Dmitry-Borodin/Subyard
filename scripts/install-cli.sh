#!/usr/bin/env bash
# install-cli.sh — symlink the stable `yard`/`sy` launcher into ~/.local/bin and ensure it's on PATH.
# Operator, no sudo. A child can't change the current shell's PATH — it prints the
# one activation command. Env: YARD_BIN_DIR, YARD_SHELL_RC; flag -y.
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
# shellcheck source=scripts/lib/cache.sh
. "$SCRIPT_DIR/lib/cache.sh"
# shellcheck source=scripts/lib-power.sh
. "$SCRIPT_DIR/lib-power.sh"
# shellcheck source=scripts/lib/host.sh
. "$SCRIPT_DIR/lib/host.sh"

REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
YARD_SRC="$REPO/bin/yard"
YARD_ENGINE="$REPO/bin/yard-engine"
BIN_DIR="${YARD_BIN_DIR:-$HOME/.local/bin}"

[ -x "$YARD_SRC" ] || die "yard launcher not found at $YARD_SRC"
[ -x "$YARD_ENGINE" ] || die "checked-in yard engine not found at $YARD_ENGINE"

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

# Shell-appropriate completion file to source from the rc.
case "$RC" in
  *zsh*) COMP="$REPO/completions/yard.zsh" ;;
  *)     COMP="$REPO/completions/yard.bash" ;;
esac

lines=("Symlink: $BIN_DIR/yard and $BIN_DIR/sy → $YARD_SRC")
if [ "$need_path_line" = 1 ]; then
  lines+=("Add $BIN_DIR to PATH via $RC (it is not on PATH yet).")
else
  lines+=("$BIN_DIR is already on PATH — no shell rc change.")
fi
lines+=("Enable tab-completion by sourcing $COMP from $RC.")
announce "Install the yard CLI" "${lines[@]}"
proceed_or_die

install -d "$BIN_DIR"
ln -sf "$YARD_SRC" "$BIN_DIR/yard"
ln -sf "$YARD_SRC" "$BIN_DIR/sy"
ok "linked $BIN_DIR/{yard,sy} → bin/yard (checked-in engine)"

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
