#!/usr/bin/env bash
# 99-teardown.sh — tear down the Subyard deployment: the yard instance, the 'subyard'
# project + its /srv volume, the Incus bridge, the storage pool + ITS DATA, and the host
# config that init added (NetworkManager guard, ufw rules, ssh client config, machine
# state). Leaves the 'incus' package, the 'incus-admin' group, and the yard CLI in place
# (those are tools, not deployment) — so 'yard init' can rebuild from scratch.
#
#   yard teardown              full teardown INCLUDING all /srv data (frees disk)
#   yard teardown --keep-data  keep the pool + /srv volume + bridge; remove only the
#                              instance + client config (fast rebuild, data preserved)
#
# Idempotent; safe to re-run. Self-elevates (root needed for NM/ufw/storage data).
# ORDER MATTERS: the instance (and its veth) goes BEFORE the bridge, and the NM guard is
# removed LAST — so teardown can never leave a veth for NetworkManager to hijack the host.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

# The operator (not root) owns ~/.ssh, ~/.subyard, ~/.config/subyard. Resolve the real
# operator user for the cleanup below (chown/removal); $SUBYARD_HOME / $SUBYARD_CONFIG_HOME
# are already under that operator via lib.sh's auto-load, even after the sudo re-exec.
OPERATOR_USER="${SUBYARD_USER:-${SUDO_USER:-${USER:-root}}}"
OPERATOR_HOME="$(getent passwd "$OPERATOR_USER" | cut -d: -f6)"
[ -n "$OPERATOR_HOME" ] || OPERATOR_HOME="$HOME"

INCUS_PROJECT="${INCUS_PROJECT:-subyard}"
INSTANCE_NAME="${INSTANCE_NAME:-yard}"
SRV_POOL="${SRV_POOL:-default}"
SRV_VOLUME="${SRV_VOLUME:-yard-srv}"
STORAGE_POOL="${STORAGE_POOL:-default}"
BRIDGE="${INCUS_BRIDGE:-${INCUS_NETWORK:-incusbr0}}"
STORAGE_PATH="${STORAGE_PATH:-$SUBYARD_HOME/incus/storage}"

KEEP_DATA=0
# Reject unknown flags: a typo like `--keepdata` MUST NOT silently fall through to a FULL,
# data-destroying teardown. `-y`/`--yes`/`-h`/`--help` are consumed by lib.sh (present in argv
# here), so tolerate them; anything else that looks like a flag is a fatal error.
for a in "$@"; do
  case "$a" in
    --keep-data) KEEP_DATA=1 ;;
    -y | --yes | -h | --help) ;;
    -*) die "unknown option '$a' (did you mean --keep-data?)" ;;
    # teardown takes NO positional args; a bare word (e.g. `keepdata` without the dashes) must NOT
    # slip through to a FULL, data-destroying teardown — reject it too, not just dash-flags.
    *) die "unexpected argument '$a' — teardown takes no positional args (only --keep-data)" ;;
  esac
done

# --- announce ----------------------------------------------------------------
if [ "$KEEP_DATA" = 1 ]; then
  announce "Subyard teardown — KEEP DATA ($INSTANCE_NAME)" \
    "Delete the '$INSTANCE_NAME' instance (project '$INCUS_PROJECT')." \
    "KEEP the storage pool, the '$SRV_VOLUME' volume and all /srv data, the project, and the '$BRIDGE' bridge." \
    "Remove client config: ufw rules, ssh client config (~/.ssh/subyard.config), machine state (~/.config/subyard)." \
    "Keep the NetworkManager guard (the bridge stays), the 'incus' package, and the yard CLI."
else
  announce "Subyard teardown — FULL (frees disk)" \
    "Delete the '$INSTANCE_NAME' instance and the '$INCUS_PROJECT' project (with its '$SRV_VOLUME' volume)." \
    "Delete the '$BRIDGE' bridge and the '$STORAGE_POOL' storage pool (only if no other Incus instances use them)." \
    "DELETE ALL DATA under $STORAGE_PATH (the yard rootfs + /srv) — frees the disk, IRREVERSIBLE." \
    "Remove host config: NetworkManager guard, ufw rules, ssh client config, machine state (~/.subyard, ~/.config/subyard)." \
    "Keep the 'incus' package, the 'incus-admin' group, and the yard CLI (so 'yard init' can rebuild)."
fi
proceed_or_die
require_root "removing the NetworkManager guard, ufw rules, and the Incus storage data needs root"

# FULL teardown only: incus INSTALLED but the daemon UNREACHABLE is the incident #33 shape (a
# failed upgrade leaves incusd down). We must not read "can't reach the daemon" as "nothing
# exists": that would set bridge_gone/pool_gone below, then `rm -rf $SUBYARD_HOME` would wipe the
# backing data of a pool still live in Incus's DB and drop the NM guard while the bridge is up.
# Refuse until the daemon is back — start/repair it, or purge the package if incus is truly gone.
# Scoped to KEEP_DATA=0: the --keep-data path never wipes data or the guard (both gated on
# KEEP_DATA=0 below), so a down daemon there is harmless and must not be blocked.
if [ "$KEEP_DATA" = 0 ] && command -v incus >/dev/null 2>&1 && ! incus info >/dev/null 2>&1; then
  die "incus is installed but its daemon is unreachable — start or repair incusd before teardown (a down daemon must not be treated as 'nothing to remove'; see incident #33)"
fi

have_incus=0
if command -v incus >/dev/null 2>&1 && incus info >/dev/null 2>&1; then have_incus=1; fi
PROJ=(--project "$INCUS_PROJECT")
# Gate guard/data removal on the bridge/pool actually being gone (avoid orphan + hijack). On a FULL
# teardown the guard above means have_incus=0 here implies incus is genuinely ABSENT; on --keep-data
# have_incus=0 may mean the daemon is down, but that path wipes neither data nor the guard, so
# bridge_gone=pool_gone=1 is harmless there.
bridge_gone=0; pool_gone=0
[ "$have_incus" = 1 ] || { bridge_gone=1; pool_gone=1; }

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
    # A project must be EMPTY to delete: drop its volume, cached images, extra
    # profiles, and the devices on its own default profile.
    if incus storage volume show "$SRV_POOL" "$SRV_VOLUME" "${PROJ[@]}" >/dev/null 2>&1; then
      incus storage volume delete "$SRV_POOL" "$SRV_VOLUME" "${PROJ[@]}" >/dev/null 2>&1 \
        && ok "deleted volume '$SRV_VOLUME'" || warn "could not delete volume '$SRV_VOLUME'"
    else
      ok "volume '$SRV_VOLUME' absent"
    fi
    while IFS= read -r fp; do
      [ -n "$fp" ] || continue
      incus image delete "$fp" "${PROJ[@]}" >/dev/null 2>&1 && ok "deleted cached image ${fp:0:12}" || true
    done < <(incus image list "${PROJ[@]}" -f csv -c f 2>/dev/null)
    while IFS= read -r prof; do
      [ -n "$prof" ] && [ "$prof" != default ] || continue
      incus profile delete "$prof" "${PROJ[@]}" >/dev/null 2>&1 && ok "deleted profile '$prof'" || true
    done < <(incus profile list "${PROJ[@]}" -f csv -c n 2>/dev/null)
    incus profile device remove default eth0 "${PROJ[@]}" >/dev/null 2>&1 || true
    incus profile device remove default root "${PROJ[@]}" >/dev/null 2>&1 || true
    if incus project delete "$INCUS_PROJECT" >/dev/null 2>&1; then
      ok "deleted project '$INCUS_PROJECT'"
    else
      warn "could not delete project '$INCUS_PROJECT' (inspect: sudo incus project show $INCUS_PROJECT)"
    fi
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
      if ! incus network show "$BRIDGE" >/dev/null 2>&1; then
        bridge_gone=1; ok "bridge '$BRIDGE' absent"
      elif incus network delete "$BRIDGE" >/dev/null 2>&1; then
        bridge_gone=1; ok "deleted bridge '$BRIDGE'"
      else
        warn "bridge '$BRIDGE' not deleted (still in use) — keeping the NetworkManager guard"
      fi
      if ! incus storage show "$STORAGE_POOL" >/dev/null 2>&1; then
        pool_gone=1; ok "storage pool '$STORAGE_POOL' absent"
      elif incus storage delete "$STORAGE_POOL" >/dev/null 2>&1; then
        pool_gone=1; ok "deleted storage pool '$STORAGE_POOL'"
      else
        warn "pool '$STORAGE_POOL' not deleted (still in use) — keeping its data dir to avoid an orphan"
      fi
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
elif [ "$pool_gone" = 1 ]; then
  rm -rf "$SUBYARD_HOME" && ok "removed $SUBYARD_HOME (storage data, ssh keys, logs)"
else
  rm -rf "$SUBYARD_HOME/ssh" "$SUBYARD_HOME/logs" 2>/dev/null || true
  warn "kept $STORAGE_PATH — pool '$STORAGE_POOL' still references it; delete the pool, then: sudo rm -rf $SUBYARD_HOME"
fi

# --- 5. NetworkManager guard — LAST (bridge + veths are gone by now) ----------
# Remove the NM guard ONLY once the bridge is gone — otherwise NM could start managing a
# still-present incusbr0 and re-introduce a rogue route. Keep it while the bridge remains.
# Gate on the ACTUAL kernel link, not just the incus-side flag: if the bridge device is still up
# for any reason (incus deleted it but the link lingered, or the flag was set optimistically),
# dropping the guard could let NM hijack the host route (incident #33). `ip` is always present.
bridge_link_gone=0
ip link show "$BRIDGE" >/dev/null 2>&1 || bridge_link_gone=1
if [ "$KEEP_DATA" = 0 ] && [ "$bridge_gone" = 1 ] && [ "$bridge_link_gone" = 1 ]; then
  echo "NetworkManager guard:"
  rm -f /etc/NetworkManager/conf.d/zz-subyard-unmanaged.conf 2>/dev/null || true
  rm -f /etc/NetworkManager/conf.d/99-subyard-unmanaged.conf 2>/dev/null || true
  if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    systemctl reload NetworkManager 2>/dev/null || nmcli general reload 2>/dev/null || true
    ok "removed NetworkManager guard + reloaded NM"
  else
    ok "removed NetworkManager guard file (NM not active)"
  fi
elif [ "$KEEP_DATA" = 0 ]; then
  echo "NetworkManager guard:"
  warn "kept the NetworkManager guard — bridge '$BRIDGE' still present (removing it now could let NM hijack the route)"
fi

echo
if [ "$KEEP_DATA" = 1 ]; then ok "Subyard teardown done (data kept)."; else ok "Subyard teardown done."; fi
cat <<MSG

Verify the host is clean (use sudo — plain 'incus' fails without the incus-admin group):
  sudo incus list --all-projects      # expect an empty table
  sudo incus network list             # no '$BRIDGE'
  ip route show default               # only your real gateway — no veth/$BRIDGE default
  ip -br link show | grep -iE 'veth|$BRIDGE' || echo 'no incus interfaces (good)'

Rebuild any time:   yard init
To ALSO remove Incus itself (DANGEROUS — only if nothing else on this host uses it):
  sudo apt-get remove --purge incus incus-client     # all instances must be gone first
MSG
