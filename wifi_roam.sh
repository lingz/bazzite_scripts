#!/usr/bin/env bash
set -euo pipefail

# wifi_roam.sh
# Robust, idempotent Wi-Fi BSSID lock/unlock/status/toggle for NetworkManager
# Fixes nmcli escaped colons (\:) so status reports correctly.

DEBUG=0
if [[ "${1:-}" == "--debug" ]]; then
  DEBUG=1
  shift
fi

log() { echo "$*"; }
dbg() { [[ "$DEBUG" -eq 1 ]] && echo "DEBUG: $*" >&2 || true; }
die() { echo "ERROR: $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

# nmcli sometimes escapes colons as "\:" in certain outputs.
normalize_bssid() {
  echo "${1:-}" | sed 's/\\:/:/g'
}

# Active connected Wi-Fi device
get_wifi_dev() {
  nmcli -t -f DEVICE,TYPE,STATE dev status \
    | awk -F: '$2=="wifi" && $3=="connected" {print $1; exit}'
}

# Active connection ID (human name) + UUID (true identity)
get_active_conn_id() {
  local dev="$1"
  nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null | head -n1
}

get_active_conn_uuid() {
  local dev="$1"
  nmcli -g GENERAL.CON-UUID device show "$dev" 2>/dev/null | head -n1
}

# Current BSSID (prefer iw to avoid scans)
get_current_bssid() {
  local dev="$1"
  if command -v iw >/dev/null 2>&1; then
    iw dev "$dev" link 2>/dev/null | awk '/Connected to/ {print $3; exit}'
  else
    nmcli -t -f ACTIVE,BSSID dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}'
  fi
}

# Read lock state from NM profile by UUID
get_locked_bssid_by_uuid() {
  local uuid="$1"
  nmcli -g 802-11-wireless.bssid connection show uuid "$uuid" 2>/dev/null | head -n1
}

# Helpful: show duplicates (multiple profiles with same ID)
show_matching_profiles() {
  local id="$1"
  nmcli -t -f NAME,UUID,TYPE connection show \
    | awk -F: -v id="$id" '$1==id {print}'
}

is_mac() {
  [[ "${1:-}" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

bounce_conn_uuid() {
  local uuid="$1"
  nmcli connection down uuid "$uuid" >/dev/null 2>&1 || true
  nmcli connection up uuid "$uuid" >/dev/null 2>&1 || true
}

status() {
  need_cmd nmcli

  local dev id uuid cur locked

  dev="$(get_wifi_dev || true)"
  [[ -n "${dev:-}" ]] || { log "Wi-Fi: DISCONNECTED"; return 0; }

  id="$(get_active_conn_id "$dev")"
  uuid="$(get_active_conn_uuid "$dev")"
  cur="$(get_current_bssid "$dev" || true)"
  locked="$(get_locked_bssid_by_uuid "$uuid" || true)"

  cur="$(normalize_bssid "$cur")"
  locked="$(normalize_bssid "$locked")"

  [[ -n "${cur:-}" ]] || cur="-"
  [[ -n "${locked:-}" ]] || locked="-"
  [[ -n "${id:-}" ]] || id="(unknown)"
  [[ -n "${uuid:-}" ]] || uuid="(unknown)"

  if [[ "$DEBUG" -eq 1 ]]; then
    dbg "dev=$dev"
    dbg "active_id=$id"
    dbg "active_uuid=$uuid"
    dbg "current_bssid=$cur"
    dbg "locked_bssid(field)=$locked"
    dbg "profiles_with_same_name:"
    show_matching_profiles "$id" | sed 's/^/DEBUG:   /' >&2 || true
  fi

  if is_mac "$locked"; then
    if [[ "$cur" != "-" && "${locked,,}" == "${cur,,}" ]]; then
      log "Wi-Fi: LOCKED ✅  SSID='${id}'  BSSID=${cur}"
    else
      log "Wi-Fi: LOCKED ⚠️  SSID='${id}'  Locked=${locked}  Current=${cur}"
    fi
  else
    log "Wi-Fi: UNLOCKED  SSID='${id}'  Current BSSID=${cur}"
  fi
}

lock() {
  need_cmd nmcli

  local dev id uuid cur locked

  dev="$(get_wifi_dev || true)"
  [[ -n "${dev:-}" ]] || die "Wi-Fi is not connected."

  id="$(get_active_conn_id "$dev")"
  uuid="$(get_active_conn_uuid "$dev")"
  [[ -n "${uuid:-}" && "$uuid" != "--" ]] || die "Could not get active connection UUID."

  cur="$(get_current_bssid "$dev" || true)"
  cur="$(normalize_bssid "$cur")"
  [[ -n "${cur:-}" ]] || die "Could not determine current BSSID (install 'iw' to avoid scans)."
  is_mac "$cur" || die "Current BSSID doesn't look valid: $cur"

  locked="$(get_locked_bssid_by_uuid "$uuid" || true)"
  locked="$(normalize_bssid "$locked")"

  if is_mac "$locked" && [[ "${locked,,}" == "${cur,,}" ]]; then
    log "Already locked ✅ (${cur})"
    return 0
  fi

  log "Locking '${id}' (uuid ${uuid}) to BSSID ${cur} ..."
  nmcli connection modify uuid "$uuid" 802-11-wireless.bssid "$cur"

  # Verify it set
  locked="$(get_locked_bssid_by_uuid "$uuid" || true)"
  locked="$(normalize_bssid "$locked")"
  dbg "after_set_locked=$locked"

  # Reconnect to apply
  bounce_conn_uuid "$uuid"

  locked="$(get_locked_bssid_by_uuid "$uuid" || true)"
  locked="$(normalize_bssid "$locked")"

  if is_mac "$locked"; then
    log "Locked ✅ (${locked})"
  else
    log "Lock command ran, but NM still reports no bssid lock."
    log "Run: $0 --debug status"
  fi
}

unlock() {
  need_cmd nmcli

  local dev id uuid locked

  dev="$(get_wifi_dev || true)"
  [[ -n "${dev:-}" ]] || { log "Wi-Fi disconnected; nothing to unlock."; return 0; }

  id="$(get_active_conn_id "$dev")"
  uuid="$(get_active_conn_uuid "$dev")"
  [[ -n "${uuid:-}" && "$uuid" != "--" ]] || die "Could not get active connection UUID."

  locked="$(get_locked_bssid_by_uuid "$uuid" || true)"
  locked="$(normalize_bssid "$locked")"

  if ! is_mac "$locked"; then
    log "Already unlocked ✅"
    return 0
  fi

  log "Unlocking '${id}' (uuid ${uuid}) (clearing BSSID ${locked}) ..."
  nmcli connection modify uuid "$uuid" 802-11-wireless.bssid ""
  bounce_conn_uuid "$uuid"
  log "Unlocked ✅"
}

toggle() {
  local out
  out="$(status)"
  log "$out"
  if echo "$out" | grep -q "Wi-Fi: LOCKED"; then
    unlock
  elif echo "$out" | grep -q "Wi-Fi: UNLOCKED"; then
    lock
  else
    die "Can't toggle: Wi-Fi not connected."
  fi
}

usage() {
  cat <<EOF
Usage: $0 [--debug] {status|lock|unlock|toggle}
  --debug : print extra info to stderr (active UUID, duplicates, etc)
  status  : show lock state
  lock    : lock to current connected BSSID (idempotent)
  unlock  : clear lock (idempotent)
  toggle  : lock if unlocked, unlock if locked
EOF
}

cmd="${1:-status}"
case "$cmd" in
  status|lock|unlock|toggle) "$cmd" ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
