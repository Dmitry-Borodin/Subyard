#!/usr/bin/env bash
# 99-uninstall.sh — tear down the Subyard deployment: the yard instance, the 'subyard'
# project + its /srv volume, the Incus bridge, the storage pool + ITS DATA, and the host
# config that setup added (NetworkManager guard, ufw rules, ssh client config, machine
# state). Leaves the 'incus' package, the 'incus-admin' group, and the yard CLI in place
# (those are tools, not deployment) — so 'yard setup' can rebuild from scratch.
#
#   yard uninstall              full teardown INCLUDING all /srv data (frees disk)
#   yard uninstall --keep-data  keep the pool + /srv volume + bridge; remove only the
#                               instance + client config (fast rebuild, data preserved)
#
# Idempotent; safe to re-run. Self-elevates (root needed for NM/ufw/storage data).
# ORDER MATTERS: the instance (and its veth) goes BEFORE the bridge, and the NM guard is
# removed LAST — so teardown can never leave a veth for NetworkManager to hijack the host.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

for cfg in incus.project.env subyard.env; do
  f="$SCRIPT_DIR/../config/$cfg"
  # shellcheck disable=SC1090
  [ -r "$f" ] && . "$f"
done
INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
SRV_POOL="${SRV_POOL:-default}"
SRV_VOLUME="${SRV_VOLUME:-yard-srv}"
STORAGE_POOL="${STORAGE_POOL:-default}"
BRIDGE="${INCUS_BRIDGE:-${INCUS_NETWORK:-incusbr0}}"

KEEP_DATA=0
for a in "$@"; do case "$a" in --keep-data) KEEP_DATA=1 ;; esac; done

# The operator (not root) owns ~/.ssh, ~/.subyard, ~/.config/subyard. Resolve them even
# after the sudo re-exec (when $HOME would otherwise be root's).
OPERATOR_USER="${SUBYARD_USER:-${SUDO_USER:-${USER:-root}}}"
OPERATOR_HOME="$(getent passwd "$OPERATOR_USER" | cut -d: -f6)"
[ -n "$OPERATOR_HOME" ] || OPERATOR_HOME="$HOME"
SUBYARD_HOME="${SUBYARD_HOME:-$OPERATOR_HOME/.subyard}"
SUBYARD_CONFIG_HOME="${SUBYARD_CONFIG_HOME:-$OPERATOR_HOME/.config/subyard}"
STORAGE_PATH="${STORAGE_PATH:-$SUBYARD_HOME/storage}"

# --- announce ----------------------------------------------------------------
if [ "$KEEP_DATA" = 1 ]; then
  announce "Subyard uninstall — KEEP DATA ($INSTANCE_NAME)" \
    "Delete the '$INSTANCE_NAME' instance (project '$INCUS_PROJECT')." \
    "KEEP the storage pool, the '$SRV_VOLUME' volume and all /srv data, the project, and the '$BRIDGE' bridge." \
    "Remove client config: ufw rules, ssh client config (~/.ssh/subyard.config), machine state (~/.config/subyard)." \
    "Keep the NetworkManager guard (the bridge stays), the 'incus' package, and the yard CLI."
else
  announce "Subyard uninstall — FULL (frees disk)" \
    "Delete the '$INSTANCE_NAME' instance and the '$INCUS_PROJECT' project (with its '$SRV_VOLUME' volume)." \
    "Delete the '$BRIDGE' bridge and the '$STORAGE_POOL' storage pool (only if no other Incus instances use them)." \
    "DELETE ALL DATA under $STORAGE_PATH (the yard rootfs + /srv) — frees the disk, IRREVERSIBLE." \
    "Remove host config: NetworkManager guard, ufw rules, ssh client config, machine state (~/.subyard, ~/.config/subyard)." \
    "Keep the 'incus' package, the 'incus-admin' group, and the yard CLI (so 'yard setup' can rebuild)."
fi
proceed_or_die
require_root "removing the NetworkManager guard, ufw rules, and the Incus storage data needs root"

have_incus=0
if command -v incus >/dev/null 2>&1 && incus info >/dev/null 2>&1; then have_incus=1; fi
PROJ=(--project "$INCUS_PROJECT")

# --- 1. instance(s) in the subyard project (removes their veths cleanly) -----
echo "Instance:"
if [ "$have_incus" = 1 ] && incus project show "$INCUS_PROJECT" >/dev/null 2>&1; then
  while IFS= read -r inst; do
    [ -n "$inst" ] || continue
    if incus delete -f "$inst" "${PROJ[@]}"; then ok "deleted instance '$inst'"; else warn "could not delete instance '$inst'"; fi
  done < <(incus list "${PROJ[@]}" -c n -f csv 2>/dev/null)
  ok "no instances left in '$INCUS_PROJECT'"
else
  ok "Incus not reachable or project '$INCUS_PROJECT' absent — nothing to delete"
fi

if [ "$KEEP_DATA" = 0 ]; then
  # --- 2. custom volume + project ------------------------------------------
  echo "Project + volume:"
  if [ "$have_incus" = 1 ] && incus project show "$INCUS_PROJECT" >/dev/null 2>&1; then
    if incus storage volume show "$SRV_POOL" "$SRV_VOLUME" "${PROJ[@]}" >/dev/null 2>&1; then
      if incus storage volume delete "$SRV_POOL" "$SRV_VOLUME" "${PROJ[@]}"; then ok "deleted volume '$SRV_VOLUME'"; else warn "could not delete volume '$SRV_VOLUME'"; fi
    else
      ok "volume '$SRV_VOLUME' absent"
    fi
    if incus project delete "$INCUS_PROJECT"; then ok "deleted project '$INCUS_PROJECT'"; else warn "could not delete project '$INCUS_PROJECT' (still has objects?)"; fi
  else
    ok "project '$INCUS_PROJECT' absent"
  fi

  # --- 3. global Incus objects (bridge + pool) — only if no OTHER instances --
  echo "Bridge + storage pool:"
  if [ "$have_incus" = 1 ]; then
    others="$(incus list --all-projects -c n -f csv 2>/dev/null | grep -v '^$' || true)"
    if [ -n "$others" ]; then
      warn "other Incus instances exist — keeping shared bridge '$BRIDGE' and pool '$STORAGE_POOL':"
      printf '%s\n' "$others" | sed 's/^/      - /'
    else
      # Clear the admin-init 'default' profile so the network/pool are unreferenced.
      incus profile device remove default eth0 >/dev/null 2>&1 || true
      incus profile device remove default root >/dev/null 2>&1 || true
      if incus network delete "$BRIDGE" >/dev/null 2>&1; then ok "deleted bridge '$BRIDGE'"; else warn "bridge '$BRIDGE' not deleted (absent or in use)"; fi
      if incus storage delete "$STORAGE_POOL" >/dev/null 2>&1; then ok "deleted storage pool '$STORAGE_POOL'"; else warn "pool '$STORAGE_POOL' not deleted (absent or in use) — its data dir is removed below regardless"; fi
    fi
  fi
fi

# --- 4. host config (operator-owned; we are root here) -----------------------
echo "Host config:"
# ufw rules (reverse of 06-network.sh) — best-effort, only if ufw present.
if command -v ufw >/dev/null 2>&1; then
  ufw delete allow in on "$BRIDGE" to any port 67 proto udp >/dev/null 2>&1 || true
  ufw delete allow in on "$BRIDGE" to any port 53 >/dev/null 2>&1 || true
  ufw route delete allow in on "$BRIDGE" >/dev/null 2>&1 || true
  ufw route delete allow out on "$BRIDGE" >/dev/null 2>&1 || true
  ok "removed Subyard ufw rules for '$BRIDGE' (if any)"
fi
# ssh client config (reverse of 07-ssh-access.sh)
snip="$OPERATOR_HOME/.ssh/subyard.config"; cfg="$OPERATOR_HOME/.ssh/config"
rm -f "$snip" && ok "removed ~/.ssh/subyard.config (if present)"
if [ -f "$cfg" ] && grep -qxF "Include subyard.config" "$cfg"; then
  grep -vxF "Include subyard.config" "$cfg" > "$cfg.tmp" && mv -f "$cfg.tmp" "$cfg"
  chown "$OPERATOR_USER":"$(id -gn "$OPERATOR_USER" 2>/dev/null || echo "$OPERATOR_USER")" "$cfg" 2>/dev/null || true
  ok "removed 'Include subyard.config' from ~/.ssh/config"
fi
# machine-local state (project pointers) — always; meaningless without the yard.
rm -rf "$SUBYARD_CONFIG_HOME" && ok "removed $SUBYARD_CONFIG_HOME"
if [ "$KEEP_DATA" = 1 ]; then
  ok "kept data: $STORAGE_PATH (and $SUBYARD_HOME)"
else
  rm -rf "$SUBYARD_HOME" && ok "removed $SUBYARD_HOME (storage data, ssh keys, logs)"
fi

# --- 5. NetworkManager guard — LAST (bridge + veths are gone by now) ----------
if [ "$KEEP_DATA" = 0 ]; then
  echo "NetworkManager guard:"
  rm -f /etc/NetworkManager/conf.d/zz-subyard-unmanaged.conf 2>/dev/null || true
  rm -f /etc/NetworkManager/conf.d/99-subyard-unmanaged.conf 2>/dev/null || true
  if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    systemctl reload NetworkManager 2>/dev/null || nmcli general reload 2>/dev/null || true
    ok "removed NetworkManager guard + reloaded NM"
  else
    ok "removed NetworkManager guard file (NM not active)"
  fi
fi

echo
if [ "$KEEP_DATA" = 1 ]; then ok "Subyard uninstall done (data kept)."; else ok "Subyard uninstall done."; fi
cat <<MSG

Verify the host is clean (use sudo — plain 'incus' fails without the incus-admin group):
  sudo incus list --all-projects      # expect an empty table
  sudo incus network list             # no '$BRIDGE'
  ip route show default               # only your real gateway — no veth/$BRIDGE default
  ip -br link show | grep -iE 'veth|$BRIDGE' || echo 'no incus interfaces (good)'

Rebuild any time:   yard setup
To ALSO remove Incus itself (DANGEROUS — only if nothing else on this host uses it):
  sudo apt-get remove --purge incus incus-client     # all instances must be gone first
MSG
