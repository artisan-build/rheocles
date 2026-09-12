# Spike S3 — time-of-day timecode

**Question (spec §16).** Write a `tmcd` track with `AVAssetWriter` stamped
from the host clock, write a Broadcast Wave with a matching `TimeReference`,
import both into Resolve, and confirm sync-by-timecode lands them together.

**Verdict: confirmed, sample-accurate.** `AVAssetWriter` writes a
time-of-day `tmcd` track that ffprobe and Resolve both read as the start
timecode; a hand-written `bext` chunk gives the BWF a `TimeReference` that
Resolve reads as the same clock. Resolve's *Auto Sync Audio → Timecode*
placed the BWF against the MOV with a sub-frame offset that matches the
host-clock difference to a hundredth of a frame (`-0.64` and `-94.41` frames
for the two takes, expected 0.63 and 94.41), and a render of the synced clip
carries the flash and the beep at the same separation the source files
have. Late-joining audio (§6) lands at its real time, not at the start.

## Method

`S3.app` (signed bundle, `NSMicrophoneUsageDescription` + audio-input
entitlement; Len granted the mic prompt once) runs `s3 record`, which from one
process and one host clock writes:

- `video.mov` — 1920×1080 30 fps HEVC, `AVAssetWriter` with
  `movieFragmentInterval` 1 s (per S2), generated frames with the host time,
  the timecode and the frame index burned in, plus a `tmcd` track
  (`kCMTimeCodeFormatType_TimeCode32`, 30 fps, 24-hour). The first frame's
  host time → seconds since local midnight × 30 → the start frame number;
  one timecode sample per second thereafter (so every fragment carries one),
  associated to the video track with `addTrackAssociation(.timecode)`.
- `audio.wav` — the SM7B through a Scarlett 2i2 via `AVCaptureAudioDataOutput`
  at 48 kHz/24-bit mono, written as RIFF/WAVE with a `bext` chunk (EBU 3285
  v1) whose `TimeReference` = seconds since midnight at the first sample ×
  48 000, taken from the sample buffer's host-time PTS. RIFF/data sizes are
  patched every second so a killed take is still readable.

At a scheduled whole second the frames go white for 200 ms and a 1 kHz tone
plays through the speakers (SM7B pointed at them), so both files see one
event. `analyze.sh` places the flash and the beep on the time-of-day clock
from each file's own stamp; `analyze-render.sh` does the same inside a
Resolve render. `--audio-delay` starts the mic late for take 2.

Resolve was driven through its scripting API (the `davinci-resolve` MCP)
under rule 3: memory pressure checked first (level 2/warn at 16 GB with
Resolve paged out; Len closed things, level 1 afterwards, Resolve quit), a
fresh scratch project `_mcp_Rheocles S3 scratch`, test timelines only, the
TWIPI project never opened. `out/resolve/resolve-evidence.txt` has the
readouts; the rendered MOV is not committed.

## Raw output

### Files (take 1, `out/take1/`)

```
[19:34:27.928] video first frame: host tod=70467.928s -> start timecode 19:34:27:27 (frame 2114037)
[19:34:27.937] audio format: 48000.0 Hz, 1 ch, 24 bit, 4 bytes/frame, flags 0x14
[19:34:27.937] audio first sample: tod=70467.921s -> bext TimeReference 3382460229 samples (= 19:34:27:27 at 30 fps)
[19:34:32.034] first flash frame at tc 19:34:32:00 (frame 123)
[19:34:42.994] video finished status=2 (2 completed, 3 failed) error=none frames=450 startTC=19:34:27:27
[19:34:42.997] audio finished: 2161152 bytes = 15.008s, TimeReference=3382460229
```

```
=== video.mov
codec_tag_string=hvc1  width=1920 height=1080  r_frame_rate=30/1  nb_frames=450   TAG:timecode=19:34:27:27
codec_tag_string=tmcd  codec_type=data                            nb_frames=15    TAG:timecode=19:34:27:27
=== audio.wav
codec_name=pcm_s24le  sample_rate=48000  channels=1  bits_per_sample=24  duration=15.008000
TAG:comment=Rheocles S3 spike  TAG:encoded_by=Rheocles  TAG:date=2026-09-11  TAG:creation_time=19:34:27
TAG:time_reference=3382460229  TAG:coding_history=A=PCM,F=48000,W=24,M=mono,T=Rheocles S3
```

```
video start tc 19:34:27:27 -> 70467.900s tod; flash at +4.100s = 70472.000s tod = 19:34:32:00
audio TimeReference 3382460229 -> 70467.921s tod; beep onset sample 199179 (peak 2827426, floor 9318, thresh 706856) = 70472.071s tod = 19:34:32:02
beep - flash = +71.0 ms (+2.13 frames at 30 fps)
```

The flash sits on the exact second it was scheduled for by the file's own
timecode. The 71 ms is the speaker→air→SM7B→USB path plus the video
timecode's floor-to-frame quantisation (≤ 33 ms); take 2 measured 74.9 ms,
so it is a stable path delay, not a stamping error.

### Files (take 2, `out/take2/`, mic started 3.1 s late)

```
[19:45:28.915] video first frame: host tod=71128.914s -> start timecode 19:45:28:27 (frame 2133867)
[19:45:32.055] mic session started late by design: running=true at video frame 75
[19:45:32.065] audio first sample: tod=71132.047s -> bext TimeReference 3414338251 samples (= 19:45:32:01 at 30 fps)
[19:45:35.020] first flash frame at tc 19:45:35:00 (frame 183)
video start tc 19:45:28:27 -> 71128.900s tod; flash at +6.100s = 71135.000s tod = 19:45:35:00
audio TimeReference 3414338251 -> 71132.047s tod; beep onset sample 145344 (...) = 71135.075s tod = 19:45:35:02
beep - flash = +74.9 ms (+2.25 frames at 30 fps)
```

### Resolve (`out/resolve/resolve-evidence.txt`)

```
video.mov  Start TC 19:34:27:27  End TC 19:34:42:27  FPS 30  Frames 450  Video Codec "H.265 Main L4.0"
audio.wav  Start TC 19:34:27:27  Sample Rate 48000  Audio Bit Depth 24  Description "Rheocles S3 spike"  Date Recorded 2026-09-11
auto_sync_audio(sync_method=timecode) -> success
take1 video.mov  "Synced Audio": audio.wav   "Audio Offset": -0.64     expected  0.63
take2 video.mov  "Synced Audio": audio.wav   "Audio Offset": -94.41    expected 94.41
```

Render of the take-2 synced clip (`out/resolve/take2-synced.mov`, timeline
01:00:00:00, mov/H264 + PCM), measured from the render alone:

```
rendered audio: 2 ch, first non-silent sample at 3.147s (the BWF's late start), beep onset at 6.175s
rendered video: flash at 6.100s
beep - flash in the render = +74.9 ms (+2.25 frames)
```

Same separation as the source files: Resolve placed the late audio 3.147 s
in, exactly where its timecode says, and nothing else moved.

## What this means for the build

1. **§8 holds as written.** `tmcd` from `AVAssetWriter`, `bext` by hand;
   the Writer type from S2 grows a timecode input and the BWF writer sits
   beside it.
2. **Round the start timecode to the nearest frame, not down.** Floor puts
   video up to a frame early; nearest halves the worst case. The manifest
   keeps the unrounded host time either way.
3. **Stamp from the sample's host-time PTS, not from `Date()` in the
   callback.** The `hostClockOffset` trick in `main.swift` is the engine's
   clock module in miniature: one offset captured at launch, every stamp
   derived from CoreMedia host time.
4. **24-bit capture arrives 24-in-32, aligned high** (`AVCaptureAudioDataOutput`,
   flags `0x14`, 4 bytes/frame). Pack the top three bytes; the first take
   wrote a "20 s" file for 15 s of audio before this was caught.
5. **Timecode samples per fragment.** One `tmcd` sample per second means a
   SIGKILLed take still carries its timecode in the fragments that survive
   (S2 + S3 together); it costs 4 bytes a second.
6. **Late join is proven end to end**: a file started 3.147 s into a take
   syncs 3.147 s in with no manifest involved (§6, §8).

No spec change is required.
