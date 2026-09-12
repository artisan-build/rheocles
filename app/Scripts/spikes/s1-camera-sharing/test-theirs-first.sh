#!/bin/sh
# Order B — theirs first. QuickTime Player opens the camera and starts
# recording; ~12 s in, the spike opens the same camera and records for 25 s.
set -u
cd "$(dirname "$0")"
DEV="${1:-4K X}"
OUT=out/theirs-first
QT="$HOME/Movies/rheocles-s1/theirs-first.mov"
rm -rf "$OUT" "$QT.qtpxcomposition"; mkdir -p "$OUT" "$(dirname "$QT")"
echo "--- launching QuickTime at $(date +%T)"
osascript quicktime.applescript 40 "$QT" > "$OUT/quicktime.log" 2>&1 &
sleep 12
./in-terminal.sh "./s1 run --device '$DEV' --seconds 25 --record $OUT/mine-fileoutput.mov --writer $OUT/mine-assetwriter.mov --label mine" "$OUT/mine.log"
wait
echo "--- QuickTime finished at $(date +%T)"; cat "$OUT/quicktime.log"
until grep -q "SUMMARY" "$OUT/mine.log" 2>/dev/null; do sleep 2; done; sleep 1
cat "$OUT/mine.log"
cp "$QT.qtpxcomposition/Movie Recording.mov" "$OUT/quicktime.mov" 2>/dev/null
for f in "$OUT"/*.mov; do
  echo "--- ffprobe $f:"
  ffprobe -v error -show_entries format=duration,size:stream=codec_type,codec_name,width,height,r_frame_rate,avg_frame_rate,nb_frames -of default=nw=1 "$f"
done | tee "$OUT/ffprobe.txt"
echo "=== DONE theirs-first"
