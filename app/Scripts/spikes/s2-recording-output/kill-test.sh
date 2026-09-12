#!/bin/sh
# Records a display with the given mechanism, then either stops cleanly or
# kills the process with SIGKILL mid-take, and reads back whatever is on disk.
#
#   ./kill-test.sh rec-output clean|kill [extra s2 args]
#   ./kill-test.sh writer     clean|kill [extra s2 args]
#   NAME=window-clean ./kill-test.sh writer clean --window Solo
#
# The app is launched with `open` so it runs as its own TCC-attributed process
# (the signed bundle id), logging to out/<name>.log.
set -u
cd "$(dirname "$0")"
MODE="$1"; FATE="$2"; shift 2
NAME="${NAME:-$MODE-$FATE}"
DIR="$PWD/out"; mkdir -p "$DIR"
LOG="$DIR/$NAME.log"; MOV="$DIR/$NAME.mov"
rm -f "$LOG" "$MOV"
SECS=20; [ "$FATE" = kill ] && SECS=60
open -n --stdout "$LOG" --stderr "$LOG" -a "$PWD/S2.app" --args "$MODE" --seconds $SECS --out "$MOV" "$@"
until grep -q "capture started\|failed\|Assertion" "$LOG" 2>/dev/null; do sleep 1; done
if grep -q "failed\|Assertion" "$LOG"; then cat "$LOG"; exit 1; fi
if [ "$FATE" = kill ]; then
  sleep 12
  PID=$(grep -o "pid [0-9]*" "$LOG" | head -1 | cut -d' ' -f2)
  echo "--- kill -9 $PID at $(date +%T) (file size now $(stat -f %z "$MOV" 2>/dev/null || echo 0))" | tee -a "$LOG"
  kill -9 "$PID"
  sleep 2
else
  until grep -q "^\[.*\] done;" "$LOG" 2>/dev/null; do sleep 1; done
fi
{
  echo "=== $NAME: $(stat -f %z "$MOV" 2>/dev/null || echo 0) bytes"
  echo "--- boxes:"; python3 boxes.py "$MOV"
  echo "--- ffprobe:"; ffprobe -v error -show_entries format=format_name,duration,size:stream=codec_name,width,height,r_frame_rate,nb_frames -of default=nw=1 "$MOV"
  echo "--- ffmpeg full decode:"; ffmpeg -v error -i "$MOV" -f null - 2>&1 && echo "decode ok"
  echo "--- AVAsset:"; ./S2.app/Contents/MacOS/s2 probe "$MOV"
} 2>&1 | tee "$DIR/$NAME.verify.txt"
