#!/bin/sh
# Control — two instances of the spike itself, same default configuration,
# so a second open is tested without the second opener changing the format.
set -u
cd "$(dirname "$0")"
DEV="${1:-4K X}"
OUT=out/two-spikes
rm -rf "$OUT"; mkdir -p "$OUT"
./in-terminal.sh "./s1 run --device '$DEV' --seconds 30 --record $OUT/first-fileoutput.mov --writer $OUT/first-assetwriter.mov --label first" "$OUT/first.log"
sleep 8
./in-terminal.sh "./s1 run --device '$DEV' --seconds 15 --writer $OUT/second-assetwriter.mov --label second" "$OUT/second.log"
until grep -q "SUMMARY" "$OUT/first.log" 2>/dev/null; do sleep 2; done; sleep 1
cat "$OUT/first.log"; echo; cat "$OUT/second.log"
for f in "$OUT"/*.mov; do
  echo "--- ffprobe $f:"
  ffprobe -v error -show_entries format=duration,size:stream=codec_type,codec_name,width,height,r_frame_rate,avg_frame_rate,nb_frames -of default=nw=1 "$f"
done | tee "$OUT/ffprobe.txt"
echo "=== DONE two-spikes"
