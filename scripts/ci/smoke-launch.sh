#!/bin/bash
# Mount a built DMG, launch the app from it, and check it is still running after a while.
# Catches apps that crash on launch (bad signature, missing entitlement, startup bug).
set -euo pipefail
DMG=$1
WAIT=${WAIT_SECONDS:-15}
MOUNT=$(mktemp -d)
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
cleanup() {
  pkill -x LedgerAtlas 2>/dev/null || true
  sleep 2
  hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
}
trap cleanup EXIT
APP="$MOUNT/Ledger Atlas.app"
[ -d "$APP" ] || { echo "app missing from DMG"; ls -la "$MOUNT"; exit 1; }
[ -L "$MOUNT/Applications" ] || { echo "Applications shortcut missing from DMG"; exit 1; }
codesign --verify --deep --strict "$APP"
open "$APP"
sleep "$WAIT"
if pgrep -x LedgerAtlas >/dev/null; then
  echo "smoke: LedgerAtlas still running after ${WAIT}s"
else
  echo "smoke: LedgerAtlas is not running after ${WAIT}s"
  find "$HOME/Library/Logs/DiagnosticReports" -name 'LedgerAtlas*' -mmin -5 \
    -exec sh -c 'echo "--- $1"; head -80 "$1"' _ {} \; 2>/dev/null || true
  exit 1
fi
