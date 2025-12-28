#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

get_wifi_dev() {
  nmcli -t -f DEVICE,TYPE,STATE dev status \
    | awk -F: '$2=="wifi" && $3=="connected" {print $1; exit}'
}

get_conn_name() {
  local dev="$1"
  nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null | head -n1
}

get_current_bssid() {
  local dev="$1"
  if command -v iw >/dev/null 2>&1; then
    iw dev "$dev" link 2>/dev/null | awk '/Connected to/ {print $3; exit}'
  else
    # Fallback (may trigger scans on some setups)
    nmcli -t -f ACTIVE,BSSID dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}'
  fi
}

get_locked_bssid() {
  local conn="$1"
  nmcli -g 802-11-wireless.bssid connection show "$conn" 2>/dev/null | head -n1
}

is_mac() {
  [[ "${1:-}" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

bounce_conn() {
  local conn="$1"
  nmcli connection down "$conn" >/dev/null 2>&1 || true
  nmcli connection up "$conn" >/dev/null 2>&1 || true
}

status_line() {
  need_cmd nmcli
  local dev conn ssid cur locked

  dev="$(get_wifi_dev || true)"
  [[ -n "${dev:-}" ]] || { echo "Wi-Fi: DISCONNECTED"; return 0; }

  conn="$(get_conn_name "$dev")"
  ssid="$(nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null | head -n1 || true)"
  cur="$(get_current_bssid "$dev" || true)"
  locked="$(get_locked_bssid "$conn" || true)"

  [[ -n "${cur:-}" ]] || cur="-"
  [[ -n "${locked:-}" ]] || locked="-"
  [[ -n "${ssid:-}" ]] || ssid="(unknown)"

  if is_mac "$locked"; then
    if [[ "$cur" != "-" && "${locked,,}" == "${cur,,}" ]]; then
      echo "Wi-Fi: LOCKED ✅  SSID='${ssid}'  BSSID=${cur}"
    else
      echo "Wi-Fi: LOCKED ⚠️  SSID='${ssid}'  Locked=${locked}  Current=${cur}"
    fi
  else
    echo "Wi-Fi: UNLOCKED  SSID='${ssid}'  Current BSSID=${cur}"
  fi
}

do_lock() {
  need_cmd nmcli
  local dev conn cur locked

  dev="$(get_wifi_dev || true)"
  [[ -n "${dev:-}" ]] || die "Wi-Fi is not connected."

  conn="$(get_conn_name "$dev")"
  [[ -n "${conn:-}" ]] || die "Could not find active NM connection profile."

  cur="$(get_current_bssid "$dev" || true)"
  [[ -n "${cur:-}" ]] || die "Could not determine current BSSID (install 'iw' for best results)."
  is_mac "$cur" || die "Current BSSID doesn't look valid: $cur"

  locked="$(get_locked_bssid "$conn" || true)"

  # Idempotent: already locked to this AP
  if is_mac "$locked" && [[ "${locked,,}" == "${cur,,}" ]]; then
    echo "Already locked ✅  (${cur})"
    return 0
  fi

  echo "Locking '${conn}' to BSSID ${cur} ..."
  nmcli connection modify "$conn" 802-11-wireless.bssid "$cur"
  bounce_conn "$conn"
  echo "Locked ✅  (${cur})"
}

do_unlock() {
  need_cmd nmcli
  local dev conn locked

  dev="$(get_wifi_dev || true)"
  [[ -n "${dev:-}" ]] || { echo "Wi-Fi disconnected; nothing to unlock."; return 0; }

  conn="$(get_conn_name "$dev")"
  [[ -n "${conn:-}" ]] || die "Could not find active NM connection profile."

  locked="$(get_locked_bssid "$conn" || true)"

  # Idempotent: already unlocked
  if ! is_mac "$locked"; then
    echo "Already unlocked ✅"
    return 0
  fi

  echo "Unlocking '${conn}' (clearing BSSID ${locked}) ..."
  nmcli connection modify "$conn" 802-11-wireless.bssid ""
  bounce_conn "$conn"
  echo "Unlocked ✅"
}

do_toggle() {
  local line
  line="$(status_line)"
  echo "$line"
  if echo "$line" | grep -q "Wi-Fi: LOCKED"; then
    do_unlock
  elif echo "$line" | grep -q "Wi-Fi: UNLOCKED"; then
    do_lock
  else
    die "Can't toggle: Wi-Fi not connected."
  fi
}

usage() {
  cat <<EOF
Usage: $0 {status|lock|unlock|toggle}
  status : show lock state
  lock   : lock to current connected BSSID (idempotent)
  unlock : clear lock (idempotent)
  toggle : lock if unlocked, unlock if locked
EOF
}

main() {
  local cmd="${1:-status}"
  case "$cmd" in
    status)  status_line ;;
    lock)    do_lock ;;
    unlock)  do_unlock ;;
    toggle)  do_toggle ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
