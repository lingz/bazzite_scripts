#!/usr/bin/env bash
set -euo pipefail

LOCK_SCRIPT="$HOME/Workspace/bazzite_scripts/wifi_roam.sh"

# ---------- helpers ----------
die() { echo "ERROR: $*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

normalize_bssid() { echo "${1:-}" | sed 's/\\:/:/g'; }

get_wifi_dev() {
  nmcli -t -f DEVICE,TYPE,STATE dev status \
    | awk -F: '$2=="wifi" && $3=="connected" {print $1; exit}'
}

get_active_uuid() {
  local dev="$1"
  nmcli -g GENERAL.CON-UUID device show "$dev" 2>/dev/null | head -n1
}

get_locked_bssid_by_uuid() {
  local uuid="$1"
  nmcli -g 802-11-wireless.bssid connection show uuid "$uuid" 2>/dev/null | head -n1
}

# ---------- state snapshot ----------
ORIG_LOCKED_BSSID=""
ORIG_CONNECTED=0
WIFI_UUID=""

snapshot_state() {
  has nmcli || die "nmcli not found"
  local dev uuid locked

  dev="$(get_wifi_dev || true)"
  if [[ -z "${dev:-}" ]]; then
    ORIG_CONNECTED=0
    ORIG_LOCKED_BSSID=""
    WIFI_UUID=""
    return 0
  fi

  ORIG_CONNECTED=1
  uuid="$(get_active_uuid "$dev" || true)"
  [[ -n "${uuid:-}" && "${uuid}" != "--" ]] || die "Could not read active Wi-Fi connection UUID."
  WIFI_UUID="$uuid"

  locked="$(get_locked_bssid_by_uuid "$WIFI_UUID" || true)"
  locked="$(normalize_bssid "$locked")"
  ORIG_LOCKED_BSSID="$locked"
}

restore_state() {
  # If Wi-Fi wasn't connected at start, don't try to change anything on exit.
  if [[ "${ORIG_CONNECTED}" -ne 1 ]]; then
    return 0
  fi

  # Restore exact previous lock state
  if [[ -n "${ORIG_LOCKED_BSSID:-}" ]]; then
    # If it was locked before, re-lock to the original BSSID (idempotent)
    nmcli connection modify uuid "$WIFI_UUID" 802-11-wireless.bssid "$ORIG_LOCKED_BSSID" >/dev/null 2>&1 || true
    nmcli connection down uuid "$WIFI_UUID" >/dev/null 2>&1 || true
    nmcli connection up   uuid "$WIFI_UUID" >/dev/null 2>&1 || true
  else
    # If it was unlocked before, unlock now (idempotent)
    "$LOCK_SCRIPT" unlock >/dev/null 2>&1 || true
  fi
}

cleanup() {
  restore_state || true
}

trap cleanup EXIT HUP INT TERM

# Snapshot state up-front (so we can restore)
snapshot_state

# Ensure locked for the session (your wifi_roam.sh is already idempotent)
"$LOCK_SCRIPT" lock >/dev/null 2>&1 || true

# ---------- launch Moonlight ----------
if has flatpak && flatpak info com.moonlight_stream.Moonlight >/dev/null 2>&1; then
  flatpak run com.moonlight_stream.Moonlight "$@" &
elif has moonlight; then
  moonlight "$@" &
else
  die "Moonlight not found (no flatpak com.moonlight_stream.Moonlight and no 'moonlight' in PATH)."
fi

MOON_PID=$!
wait "$MOON_PID"
