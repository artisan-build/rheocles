#!/bin/sh
# Closes the loop on a Resolve render of the synced clip: the rendered file's
# own video and audio are measured for the flash and the beep. If Resolve
# placed the BWF by timecode, beep - flash here equals what analyze.sh found
# in the source files (the speaker-to-mic path); if it had simply lined the
# two files up at their starts, it would be off by the audio's late start.
set -eu
cd "$(dirname "$0")"
F="$1"
echo "=== $F"
ffmpeg -v error -y -i "$F" -vn -acodec pcm_s24le "${F%.mov}-audio.wav"
ffprobe -v error -f lavfi -i "movie=$F,signalstats" -show_entries frame=pts_time:frame_tags=lavfi.signalstats.YAVG -of csv=p=0 \
  | awk -F, '$2 > 200 { print "flash pts=" $1 "s YAVG=" $2; exit }' | tee "${F%.mov}-flash.txt"
python3 - "$F" <<'PY' | tee "${F%.mov}-sync.txt"
import struct, sys, re
f = sys.argv[1]; base = f[:-4]
flash = float(re.search(r"pts=([\d.]+)", open(base + "-flash.txt").read()).group(1))
raw = open(base + "-audio.wav", "rb").read()
i = raw.find(b"data"); n = struct.unpack("<I", raw[i+4:i+8])[0]; pcm = raw[i+8:i+8+n]
ch = struct.unpack("<H", raw[raw.find(b"fmt ")+10:raw.find(b"fmt ")+12])[0]
samples = [struct.unpack("<i", pcm[k:k+3] + (b"\xff" if pcm[k+2] & 0x80 else b"\x00"))[0] for k in range(0, len(pcm), 3*ch)]
peak = max(abs(x) for x in samples)
first_sound = next(k for k, x in enumerate(samples) if abs(x) > 2000)
onset = next(k for k, x in enumerate(samples) if abs(x) > peak * 0.25)
print(f"rendered audio: {ch} ch, first non-silent sample at {first_sound/48000:.3f}s (the BWF's late start), beep onset at {onset/48000:.3f}s (peak {peak})")
print(f"rendered video: flash at {flash:.3f}s")
print(f"beep - flash in the render = {(onset/48000-flash)*1000:+.1f} ms ({(onset/48000-flash)*30:+.2f} frames)")
PY
