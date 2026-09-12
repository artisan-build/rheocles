#!/bin/sh
# Order A, variant — ours first, holding lockForConfiguration for the run. The spike opens the camera and records (both an
# AVCaptureMovieFileOutput and our own AVAssetWriter fed from the data output);
# ~8 s in, QuickTime Player opens the same camera and records for 20 s
# alongside, saving its recording so it can be probed too.
set -u
cd "$(dirname "$0")"
DEV="${1:-4K X}"
OUT=out/mine-first-locked
QT="$HOME/Movies/rheocles-s1/mine-first-locked.mov"
rm -rf "$OUT" "$QT.qtpxcomposition"; mkdir -p "$OUT" "$(dirname "$QT")"
./in-terminal.sh "./s1 run --device '$DEV' --seconds 40 --record $OUT/mine-fileoutput.mov --writer $OUT/mine-assetwriter.mov --hold-lock --label mine" "$OUT/mine.log"
sleep 8
echo "--- launching QuickTime at $(date +%T)"
osascript quicktime.applescript 20 "$QT" 2>&1 | tee "$OUT/quicktime.log"
echo "--- QuickTime finished at $(date +%T)"
until grep -q "SUMMARY" "$OUT/mine.log" 2>/dev/null; do sleep 2; done; sleep 1
cat "$OUT/mine.log"
cp "$QT.qtpxcomposition/Movie Recording.mov" "$OUT/quicktime.mov" 2>/dev/null
for f in "$OUT"/*.mov; do
  echo "--- ffprobe $f:"
  ffprobe -v error -show_entries format=duration,size:stream=codec_type,codec_name,width,height,r_frame_rate,avg_frame_rate,nb_frames -of default=nw=1 "$f"
done | tee "$OUT/ffprobe.txt"
echo "=== DONE mine-first-locked"
