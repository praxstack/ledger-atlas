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
PID=
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  sleep 2
  hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
}
trap cleanup EXIT
APP="$MOUNT/Ledger Atlas.app"
LOG="$OUT/tour.log"
LEDGER_ATLAS_DEMO_TOUR=1 "$APP/Contents/MacOS/LedgerAtlas" >"$LOG" 2>&1 &
PID=$!
# Best effort: one whole-screen frame once the demo ledger is open.
for _ in $(seq 1 60); do
  grep -q "ledger opened" "$LOG" 2>/dev/null && break
  sleep 1
done
sleep 2
screencapture -x "$OUT/00-full-screen.png" 2>>"$LOG" || echo "screencapture unavailable" >>"$LOG"
for _ in $(seq 1 120); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
kill "$PID" 2>/dev/null || true
cat "$LOG"
SRC=$(sed -n 's/^\[demo-tour\] output //p' "$LOG" | head -1)
[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "demo tour wrote no output"; exit 1; }
compgen -G "$SRC/*.png" >/dev/null || { echo "demo tour saved no screens"; exit 1; }
cp "$SRC"/*.png "$OUT"/
[ -f "$SRC/tour.txt" ] && cp "$SRC/tour.txt" "$OUT"/
count=$(ls "$OUT"/[0-9][0-9]-*.png 2>/dev/null | grep -vc "/00-" || true)
echo "demo tour: $count screens"
grep -q "ledger opened" "$LOG" || { echo "demo ledger did not open"; exit 1; }
[ "$count" -ge 10 ] || { echo "too few screens captured"; exit 1; }
# A blank or single-colour window compresses to a few KB; a real screen is far larger.
blank=0
for f in "$OUT"/[0-9][0-9]-*.png; do
  case "$(basename "$f")" in 00-*) continue ;; esac
  size=$(stat -f%z "$f")
  if [ "$size" -lt 25000 ]; then echo "looks blank: $(basename "$f") ($size bytes)"; blank=$((blank + 1)); fi
done
[ "$blank" -eq 0 ] || { echo "$blank screens look blank"; exit 1; }
# Every screen should look different; identical frames mean navigation did not happen.
distinct=$(for f in "$OUT"/[0-9][0-9]-*.png; do
  case "$(basename "$f")" in 00-*) ;; *) shasum -a 256 "$f" | cut -d' ' -f1 ;; esac
done | sort -u | wc -l | tr -d ' ')
echo "demo tour: $distinct distinct screens"
[ "$distinct" -ge 10 ] || { echo "too few distinct screens"; exit 1; }
# A walkthrough video: each screen for two seconds.
# ffmpeg from Homebrew (unpinned; the video is optional, so a failed install only skips it).
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
