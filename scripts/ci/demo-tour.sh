#!/bin/bash
# Launch the app from a built DMG in demo-tour mode. The app writes a synthetic demo ledger,
# opens it, saves a PNG of every main screen, then quits. This script collects the PNGs into
# dist/demo-tour, tries a whole-screen capture (it needs Screen Recording permission, which a
# runner may not have, so it is best effort), and turns the screens into a short video.
set -euo pipefail
DMG=$1
OUT=${OUT_DIR:-dist/demo-tour}
mkdir -p "$OUT"
MOUNT=$(mktemp -d)
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
cleanup() {
  pkill -x LedgerAtlas 2>/dev/null || true
  sleep 2
  hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
}
trap cleanup EXIT
APP="$MOUNT/Ledger Atlas.app"
LOG="$OUT/tour.log"
LEDGER_ATLAS_DEMO_TOUR=1 "$APP/Contents/MacOS/LedgerAtlas" >"$LOG" 2>&1 &
PID=$!
# Best effort: one whole-screen frame while the ledger screen is up.
sleep 12
screencapture -x "$OUT/00-full-screen.png" 2>>"$LOG" || echo "screencapture unavailable" >>"$LOG"
for _ in $(seq 1 120); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
kill "$PID" 2>/dev/null || true
cat "$LOG"
SRC=$(sed -n 's/^\[demo-tour\] output //p' "$LOG" | head -1)
[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "demo tour wrote no output"; exit 1; }
cp "$SRC"/*.png "$SRC"/tour.txt "$OUT"/
count=$(ls "$OUT"/[0-9][0-9]-*.png 2>/dev/null | grep -vc "/00-" || true)
echo "demo tour: $count screens"
grep -q "ledger opened" "$LOG" || { echo "demo ledger did not open"; exit 1; }
[ "$count" -ge 10 ] || { echo "too few screens captured"; exit 1; }
# A walkthrough video: each screen for two seconds.
if ! command -v ffmpeg >/dev/null; then brew install ffmpeg >/dev/null 2>&1 || true; fi
if command -v ffmpeg >/dev/null; then
  FRAMES=$(mktemp -d)
  for f in "$OUT"/[0-9][0-9]-*.png; do
    case "$(basename "$f")" in 00-*) ;; *) cp "$f" "$FRAMES/" ;; esac
  done
  ffmpeg -y -loglevel error -framerate 0.5 -pattern_type glob -i "$FRAMES/*.png" \
    -vf "scale=1280:-2:flags=lanczos,format=yuv420p" -r 30 -c:v libx264 -movflags +faststart \
    "$OUT/walkthrough.mp4" && echo "video: $OUT/walkthrough.mp4"
fi
