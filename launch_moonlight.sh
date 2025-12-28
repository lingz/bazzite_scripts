#!/usr/bin/env bash
set -euo pipefail

LOCK_SCRIPT="$HOME/Workspace/bazzite_scripts/wifi_roam.sh"
FLATPAK_ID="com.moonlight_stream.Moonlight"

cleanup() {
  "$LOCK_SCRIPT" unlock >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

"$LOCK_SCRIPT" lock >/dev/null 2>&1 || true

if command -v flatpak >/dev/null 2>&1 && flatpak info "$FLATPAK_ID" >/dev/null 2>&1; then
  # Foreground: wrapper stays alive until flatpak run returns
  flatpak run "$FLATPAK_ID" "$@"
elif command -v moonlight >/dev/null 2>&1; then
  moonlight "$@"
else
  echo "ERROR: Moonlight not found." >&2
  exit 1
fi
