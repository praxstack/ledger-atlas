#!/bin/bash
# Launch the app from a built DMG in demo-tour mode. The app writes a synthetic demo ledger,
# opens it, shows every main screen for 1.5 s, saves a PNG of each, then quits. This script:
#   - records the whole screen while the tour runs (tour-recording.mp4),
#   - collects the PNGs into dist/demo-tour and checks they are real, distinct screens,
#   - turns the PNGs into a slideshow (walkthrough.mp4).
# Only the synthetic demo ledger is ever shown: the app refuses to tour a Mac that has ledgers.
# Screen recording needs the runner's Screen Recording permission, so it is best effort and
# reported as "screen recording: ..." in the log. The PNG checks are strict.
#
# Runs under macOS's bash 3.2: no `case` inside $(...), which that version cannot parse.
set -euo pipefail
DMG=$1
OUT=${OUT_DIR:-dist/demo-tour}
mkdir -p "$OUT"
MOUNT=$(mktemp -d)
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
PID=
REC=
cleanup() {
  [ -n "$REC" ] && kill -INT "$REC" 2>/dev/null || true
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  sleep 2
  hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
}
trap cleanup EXIT
APP="$MOUNT/Ledger Atlas.app"
LOG="$OUT/tour.log"
RAW=$(mktemp -d)/tour-recording.mov

# ffmpeg (Homebrew, unpinned) makes both videos. Installed first so the install's own time is
# not recorded. Both videos are optional, so a failed install only skips them.
if ! command -v ffmpeg >/dev/null; then brew install ffmpeg >/dev/null 2>&1 || true; fi

# Record the screen for at most 150 s (longer than the 120 s tour wait); SIGINT below stops it early and finalises the file.
screencapture -x -v -V 150 "$RAW" >/dev/null 2>"$OUT/recording.log" &
REC=$!
sleep 1
LEDGER_ATLAS_DEMO_TOUR=1 "$APP/Contents/MacOS/LedgerAtlas" >"$LOG" 2>&1 &
PID=$!
# One whole-screen still once the demo ledger is open.
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
PID=
sleep 1
kill -INT "$REC" 2>/dev/null || true
wait "$REC" 2>/dev/null || true
REC=
cat "$LOG"

SRC=$(sed -n 's/^\[demo-tour\] output //p' "$LOG" | head -1)
[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "demo tour wrote no output"; exit 1; }
compgen -G "$SRC/*.png" >/dev/null || { echo "demo tour saved no screens"; exit 1; }
cp "$SRC"/*.png "$OUT"/
[ -f "$SRC/tour.txt" ] && cp "$SRC/tour.txt" "$OUT"/
# The app's screens are 01-…png onwards; 00-full-screen.png is the whole-screen still.
screens() { ls "$OUT"/[0-9][0-9]-*.png 2>/dev/null | grep -v '/00-' || true; }
count=$(screens | wc -l | tr -d ' ')
echo "demo tour: $count screens"
grep -q "ledger opened" "$LOG" || { echo "demo ledger did not open"; exit 1; }
[ "$count" -ge 10 ] || { echo "too few screens captured"; exit 1; }
# A blank or single-colour window compresses to a few KB; a real screen is far larger.
blank=0
for f in $(screens); do
  size=$(stat -f%z "$f")
  if [ "$size" -lt 25000 ]; then echo "looks blank: $(basename "$f") ($size bytes)"; blank=$((blank + 1)); fi
done
[ "$blank" -eq 0 ] || { echo "$blank screens look blank"; exit 1; }
# Every screen should look different; identical frames mean navigation did not happen.
distinct=$(for f in $(screens); do shasum -a 256 "$f" | cut -d' ' -f1; done | sort -u | wc -l | tr -d ' ')
echo "demo tour: $distinct distinct screens"
[ "$distinct" -ge 10 ] || { echo "too few distinct screens"; exit 1; }

command -v ffmpeg >/dev/null || { echo "ffmpeg unavailable: no videos"; exit 0; }

# The screen recording. A recording without permission shows only the desktop, so count how
# often the picture changes: the tour moves through 16 screens, so a real recording changes
# many times, while a desktop-only one barely changes.
if [ -s "$RAW" ]; then
  if ffmpeg -y -loglevel error -i "$RAW" \
    -vf "scale=1280:-2:flags=lanczos,fps=15,format=yuv420p" -c:v libx264 -crf 26 \
    -movflags +faststart -an "$OUT/tour-recording.mp4"; then
    seconds=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/tour-recording.mp4" | cut -d. -f1 || true)
    changes=$(ffmpeg -i "$OUT/tour-recording.mp4" -vf "select='gt(scene,0.02)',showinfo" \
      -f null - 2>&1 | grep -c "pts_time" || true)
    echo "screen recording: ${seconds}s, $changes scene changes"
    if [ "$changes" -lt 8 ]; then
      echo "screen recording: the screen barely changes; Screen Recording permission is probably missing"
      mv "$OUT/tour-recording.mp4" "$OUT/tour-recording-unverified.mp4"
    fi
  else
    echo "screen recording: could not convert"
  fi
else
  echo "screen recording: unavailable ($(tr '\n' ' ' <"$OUT/recording.log"))"
fi

# A slideshow walkthrough: each app screen for two seconds.
FRAMES=$(mktemp -d)
for f in $(screens); do cp "$f" "$FRAMES/"; done
ffmpeg -y -loglevel error -framerate 0.5 -pattern_type glob -i "$FRAMES/*.png" \
  -vf "scale=1280:-2:flags=lanczos,format=yuv420p" -r 30 -c:v libx264 -movflags +faststart \
  "$OUT/walkthrough.mp4" && echo "video: $OUT/walkthrough.mp4" || echo "walkthrough video: ffmpeg failed"
