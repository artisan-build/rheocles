#!/bin/sh
# Measures the one event both files saw — the white flash and the 1 kHz tone —
# and places each on the time-of-day clock from its own file's stamp alone:
#   flash: first frame whose average luma is bright, at start TC + frame index
#   beep:  first loud sample, at TimeReference + sample index
# If the stamps are right, the two land on the same time-of-day, give or take
# the speaker→mic path. Usage: ./analyze.sh out/take1
set -eu
cd "$(dirname "$0")"
DIR="$1"
echo "=== $DIR"
ffprobe -v error -show_entries stream=index,codec_type,codec_tag_string,nb_frames,r_frame_rate:stream_tags=timecode -of default=nw=1 "$DIR/video.mov"
ffprobe -v error -show_entries format_tags=time_reference,coding_history:stream=codec_name,sample_rate,channels -of default=nw=1 "$DIR/audio.wav"
echo "--- flash (first bright frame):"
ffprobe -v error -f lavfi -i "movie=$DIR/video.mov,signalstats" \
  -show_entries frame=pts_time:frame_tags=lavfi.signalstats.YAVG -of csv=p=0 \
  | awk -F, '$2 > 200 { print "pts=" $1 "s YAVG=" $2; exit }' | tee "$DIR/flash.txt"
python3 - "$DIR" <<'PY' | tee "$DIR/sync.txt"
import struct, sys, subprocess, json, re
d = sys.argv[1]
tc = subprocess.check_output(["ffprobe","-v","error","-select_streams","v:0","-show_entries","stream_tags=timecode","-of","csv=p=0",f"{d}/video.mov"]).decode().strip()
h,m,s,f = map(int, tc.split(":"))
start_tod = h*3600+m*60+s+f/30
flash_pts = float(re.search(r"pts=([\d.]+)", open(f"{d}/flash.txt").read()).group(1))
flash_tod = start_tod + flash_pts
tref = int(subprocess.check_output(["ffprobe","-v","error","-show_entries","format_tags=time_reference","-of","csv=p=0",f"{d}/audio.wav"]).decode().strip())
raw = open(f"{d}/audio.wav","rb").read()
i = raw.find(b"data"); n = struct.unpack("<I", raw[i+4:i+8])[0]; pcm = raw[i+8:i+8+n]
samples = [struct.unpack("<i", pcm[k:k+3] + (b"\xff" if pcm[k+2] & 0x80 else b"\x00"))[0] for k in range(0, len(pcm), 3)]
peak = max(abs(x) for x in samples)
floor = sorted(abs(x) for x in samples[:48000])[int(48000*0.99)]  # 99th percentile of the first second = room noise
thresh = max(peak*0.25, floor*8)
onset = next(k for k,x in enumerate(samples) if abs(x) > thresh)
beep_tod = (tref + onset)/48000
def tcs(t): 
    fr = int(round(t*30)); return "%02d:%02d:%02d:%02d" % (fr//108000, (fr//1800)%60, (fr//30)%60, fr%30)
print(f"video start tc {tc} -> {start_tod:.3f}s tod; flash at +{flash_pts:.3f}s = {flash_tod:.3f}s tod = {tcs(flash_tod)}")
print(f"audio TimeReference {tref} -> {tref/48000:.3f}s tod; beep onset sample {onset} (peak {peak}, floor {floor}, thresh {int(thresh)}) = {beep_tod:.3f}s tod = {tcs(beep_tod)}")
print(f"beep - flash = {(beep_tod-flash_tod)*1000:+.1f} ms ({(beep_tod-flash_tod)*30:+.2f} frames at 30 fps)")
PY
