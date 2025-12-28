#!/usr/bin/env bash
set -euo pipefail

LOCK_SCRIPT="$HOME/bin/wifi_roam.sh"
LOCKED=0

cleanup() {
  # Only unlock if we successfully locked in this session
  if [[ "${LOCKED}" -eq 1 ]]; then
    "$LOCK_SCRIPT" unlock >/dev/null 2>&1 || true
  fi
}

# Run cleanup on normal exit and common termination signals
trap cleanup EXIT HUP INT TERM

# Lock first (idempotent in your script)
if "$LOCK_SCRIPT" lock >/dev/null 2>&1; then
  LOCKED=1
fi

# Launch Moonlight (flatpak or native)
if command -v flatpak >/dev/null 2>&1 && flatpak info com.moonlight_stream.Moonlight >/dev/null 2>&1; then
  flatpak run com.moonlight_stream.Moonlight "$@" &
elif command -v moonlight >/dev/null 2>&1; then
  moonlight "$@" &
else
  echo "ERROR: Moonlight not found (no flatpak com.moonlight_stream.Moonlight and no 'moonlight' in PATH)." >&2
  exit 1
fi

MOON_PID=$!
wait "$MOON_PID"
