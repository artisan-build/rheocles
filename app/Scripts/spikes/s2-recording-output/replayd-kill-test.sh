#!/bin/sh
# The SCRecordingOutput file is written by /usr/libexec/replayd, not by us
# (see out/lsof.txt). Killing our process lets replayd finalise the file, so
# the real "what if the writer dies" test for that mechanism is killing
# replayd itself mid-take — the closest stand-in for a power cut. replayd is
# a per-user launchd service and respawns on demand.
set -u
cd "$(dirname "$0")"
DIR="$PWD/out"; LOG="$DIR/rec-output-replayd-kill.log"; MOV="$DIR/rec-output-replayd-kill.mov"
rm -f "$LOG" "$MOV"
open -n --stdout "$LOG" --stderr "$LOG" -a "$PWD/S2.app" --args rec-output --seconds 60 --out "$MOV"
until grep -q "capture started\|failed" "$LOG" 2>/dev/null; do sleep 1; done
sleep 12
RPID=$(lsof -t "$MOV" | head -1)
echo "--- kill -9 replayd $RPID ($(ps -o comm= -p "$RPID")) at $(date +%T) (file size now $(stat -f %z "$MOV"))" | tee -a "$LOG"
kill -9 "$RPID"
sleep 5
PID=$(grep -o "pid [0-9]*" "$LOG" | head -1 | cut -d' ' -f2)
echo "--- our process $PID alive: $(kill -0 "$PID" 2>/dev/null && echo yes || echo no); killing it too" | tee -a "$LOG"
kill -9 "$PID" 2>/dev/null
sleep 2
{
  echo "=== rec-output-replayd-kill: $(stat -f %z "$MOV" 2>/dev/null || echo 0) bytes"
  echo "--- boxes:"; python3 boxes.py "$MOV"
  echo "--- ffprobe:"; ffprobe -v error -show_entries format=format_name,duration,size:stream=codec_name,width,height,nb_frames -of default=nw=1 "$MOV"
  echo "--- ffmpeg full decode:"; ffmpeg -v error -i "$MOV" -f null - 2>&1 && echo "decode ok"
  echo "--- AVAsset:"; ./S2.app/Contents/MacOS/s2 probe "$MOV"
} 2>&1 | tee "$DIR/rec-output-replayd-kill.verify.txt"
