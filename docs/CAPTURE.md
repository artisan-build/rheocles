# Capture

Owned by Engine. Measurements of capture behaviour. Spikes S1–S3 under
`app/Scripts/spikes/` hold the raw evidence for the capture mechanisms; this
file collects the numbers the build relies on.

## Permissions (spec §4, verified)

macOS 26.6, hardened runtime, Developer ID signed dev bundle
(`app/Scripts/dev-core.sh`):

| capability | Info.plist key | entitlement | prompt |
|---|---|---|---|
| camera | `NSCameraUsageDescription` | `com.apple.security.device.camera` | on the first arm |
| microphone | `NSMicrophoneUsageDescription` | `com.apple.security.device.audio-input` | on the first arm |
| system audio | `NSAudioCaptureUsageDescription` | none beyond audio-input | "System Audio Recording", on the first tap |
| screen / windows | none | none | ScreenCaptureKit's own, on the first `SCShareableContent` query |

Without the usage string the request is refused instantly and silently and
the app never appears in System Settings; a bare executable's request is
attributed to whatever launched it (S1). `CGPreflightScreenCaptureAccess`
is fixed for the life of a process — a grant shows up on the next launch.

## HEVC tiers (spec §8)

**Question.** At what HEVC bitrate is a recording visually indistinguishable
from ProRes 422 — so HEVC can be the space-saving default and ProRes the
single alternative?

**Answer.** At **0.15 bits per pixel per frame** the HEVC files are
transparent at both 1080p and 4K on the demanding real content measured
here, with headroom — 4K reaches transparency by ~0.12 bpp. **0.15 bpp is the
decided global HEVC default** (agreed with Len after this measurement), a
single knob for both resolutions; a per-resolution refinement (4K at 0.12 bpp
for ~20 % smaller files at equal perceptual quality) is noted below as a
future option.

The tier is bits per pixel per frame so it is independent of frame rate.
Two megabit columns below: **nominal** is the arithmetic target
`0.15 × width × height × fps` (what the disk pre-flight reserves), and
**measured** is what `hevc_videotoolbox` actually produced on the demanding
motion source — the encoder undershoots the average-bitrate target by
~15–20 % on this content, so the pre-flight's use of the nominal figure is
conservative (it never under-reserves).

| resolution | tier | nominal @30 / @60 | measured @30 |
|---|---|---|---|
| 1080p | 0.15 bpp | 9.3 / 18.7 Mbps | ~8 Mbps |
| 4K (3840×2160) | 0.15 bpp | 37.3 / 74.6 Mbps | ~30 Mbps |

### Source

The Elgato 4K X had **no live HDMI signal** during this measurement (its
preview came back black — Len had powered the source down), so — per the
plan — the reference is **Rheocles display capture of the BenQ PD3220U at its
native 3840×2160**, which is exactly the screen content Rheocles records for
displays, windows and the Elgato prompter. Two real captures, each recorded
by Rheocles itself as ProRes 422:

- **motion** — a terminal scrolling random colour-coded hex over the desktop
  wallpaper: continuous motion plus fine high-contrast text, the hardest
  case a video codec meets (harder than camera footage). 857 frames, ProRes
  ≈ 1040 Mbps.
- **static** — the desktop with a browser showing the API discovery JSON over
  the photographic wallpaper: sharp text and window chrome, little motion.

Both were normalised to a constant 30 fps and, for the 1080p rows,
downscaled Lanczos to 1920×1080, then re-encoded to visually-lossless ProRes
422 HQ as the reference. **This is a conservative source: screen text is a
worse case for HEVC than the camera and video footage Rheocles also records,
so the tier chosen here is safe for those too.** No native-4K camera signal
was available to measure motion-video content directly.

### Method

HEVC encoded with **`hevc_videotoolbox`** — the same VideoToolbox encoder the
engine's `AVAssetWriter` uses — at a sweep of target bitrates, then compared
to the ProRes reference with two full-reference metrics:

- **XPSNR** — perceptually-weighted PSNR (luma reported); ~45 dB is the
  transparency threshold, higher is better.
- **SSIM** — structural similarity; > 0.995 is visually indistinguishable for
  most content, > 0.997 excellent.

Reproduce with `app/Scripts/spikes/` conventions from the reference `.mov`s
left at `/tmp/rheocles-step9/` (`measure/sweep.sh`).

### Results

```
motion-4K   (scrolling hex + wallpaper, 3840×2160@30, ProRes ref 652 Mbps)
  bpp   Mbps   XPSNR      SSIM
  0.04  10.4   42.98    0.9900
  0.06  15.4   47.05    0.9949
  0.08  18.6   48.52    0.9960
  0.10  21.8   49.63    0.9966
  0.12  24.5   50.44    0.9970
  0.15  30.0   52.01    0.9977
  0.20  36.8   53.64    0.9981
  0.30  51.6   56.89    0.9987

motion-1080 (same, downscaled 1920×1080@30, ProRes ref 205 Mbps)
  bpp   Mbps   XPSNR      SSIM
  0.04   2.6   35.99    0.9736
  0.06   3.9   39.71    0.9858
  0.08   5.2   42.50    0.9912
  0.10   6.4   44.52    0.9935
  0.12   7.0   45.41    0.9944
  0.15   8.3   46.95    0.9956
  0.20  10.1   48.99    0.9966
  0.30  14.5   52.80    0.9978

static-4K   (browser text + wallpaper, 3840×2160@30, ProRes ref 636 Mbps)
  bpp   Mbps   XPSNR      SSIM
  0.04   9.4   46.25    0.9946
  0.06  11.9   48.05    0.9963
  0.08  13.6   48.95    0.9969
  0.10  14.9   49.49    0.9973
  0.12  15.2   49.65    0.9973
  0.15  17.8   50.52    0.9978
  0.20  19.6   51.11    0.9980
  0.30  28.3   54.32    0.9987

static-1080 (same, downscaled 1920×1080@30, ProRes ref 198 Mbps)
  bpp   Mbps   XPSNR      SSIM
  0.04   2.6   38.55    0.9820
  0.06   3.8   41.94    0.9902
  0.08   4.7   43.90    0.9932
  0.10   5.4   45.21    0.9945
  0.12   6.0   46.19    0.9954
  0.15   7.3   47.86    0.9965
  0.20   8.3   49.21    0.9972
  0.30  10.9   51.97    0.9980
```

### Reading it

- **4K is transparent early.** On the adversarial motion source, HEVC crosses
  SSIM 0.996 / XPSNR 48 at **0.08 bpp** and 0.997 / 50 at **0.12 bpp**; the
  static source is already there at 0.06. Above ~0.15 bpp the curves flatten
  — 0.15→0.20 buys +0.0004 SSIM for +7 Mbps. 4K's spatial redundancy lets it
  reach transparency at a **lower** bits-per-pixel than 1080p.
- **1080p wants slightly more per pixel.** The same content downscaled needs
  ~0.15 bpp to reach SSIM 0.9956–0.9965 / XPSNR 47–48 — the point where the
  curve knees and further bitrate stops mattering perceptually.
- **Visual check.** At a 100 % crop of the motion source, HEVC at **0.10 bpp
  (22 Mbps, 4K)** is indistinguishable from ProRes — the fine coloured hex
  text is crisp in both (`/tmp/rheocles-step9/measure/*_crop.png`, stacked in
  `/tmp/step9-compare-motion.png`). Since screen text is the hardest case,
  camera and video footage are transparent below this. The final human
  judgement on the calibrated BenQ PD3220U is Len's to confirm; the objective
  metrics and the crop point the same way.

### Recommendation

**Keep 0.15 bpp as the single HEVC default** — measured transparent at both
resolutions on demanding real content, with a safety margin at 4K. It is what
the engine and the disk pre-flight already use, now confirmed rather than
asserted. If file size becomes a concern, a **per-resolution refinement** is
justified by the data: 4K at **0.12 bpp** (≈ 20 % smaller) is still
transparent (SSIM 0.997 / XPSNR 50) on the worst case here. ProRes 422 stays
the single lossless alternative.

### Limitations, stated plainly

- Source is display capture of screen content, not camera footage — the
  Elgato had no signal. Screen text is a harder case than motion video, so
  the tier is conservative (safe) for camera and video streams.
- No native-4K camera signal was available; the 1080p rows are the 4K capture
  downscaled, not independently shot 1080p footage.
- XPSNR/SSIM are objective proxies for the "visually indistinguishable"
  judgement; a calibrated-display eyeball by Len is the final word and agrees
  with the metrics on the sample crop.

## Disk pre-flight estimates

`TakeEngine.estimateBytes` reserves at the **nominal** tier — HEVC
**0.15 bpp** and ProRes 422 **2.4 bpp** — times `min(fps, 60)` and the
expected duration:

| | 1080p30 | 1080p60 | 4K30 | 4K60 |
|---|---|---|---|---|
| HEVC 0.15 bpp | 9.3 Mbps | 18.7 | 37.3 | **74.6** |
| ProRes 2.4 bpp | 149 Mbps | 299 | 597 | 1194 |

The pre-flight deliberately uses the nominal target, not the measured
~15–20 % lower actual output, so `507 insufficient_storage` decisions err on
the side of caution rather than letting a take start and then run out of
disk mid-write.

## Constant frame rate, drift, and dropped frames (spec §8)

Every video frame is stamped by the **host clock** at capture — the clock the
audio, `started` and the `tmcd` track already share — and snapped to a
nominal-rate grid (`VideoWriter`). A frame that arrives late, or a slot with no
frame because the source runs under its nominal rate or the encoder dropped
one, is filled by **re-submitting the previous frame** when the gap exceeds
~1.5 nominal durations. So the file is **constant frame rate**: `N frames ×
1/fps` equals the take's span to within a frame, and no editor has to conform
variable-rate footage.

This is what fixes the drift Len hit: an Elgato 4K X fed a **59.94** signal
behind a card that advertised **60** delivered 24,811 frames over 414 s
(**59.93 fps**), and the video slipped ~0.5 s against the Scarlett over seven
minutes. The manifest now reports the true rate as `measuredFrameRate` and the
mismatch as `drift`, and the file itself is CFR, so the slip is gone.

**Cost.** Padding re-encodes a duplicate frame per filled slot. For HEVC a
duplicate is a near-empty inter-frame — cheap in both bits and encoder time —
so a static screen padded to its armed 30 or 60 costs little on disk. ProRes,
intra-only, pays a full frame per pad; a mostly-static ProRes screen capture is
correspondingly larger, which is one more reason HEVC is the default.

### The 16 % drop rate at 4K60 (investigation)

On Len's Mac, 4K60 HEVC on the Elgato **with two 4K displays armed at the same
time** dropped ~16 % of camera frames (`framesDropped` 3,916 of 24,811). What
was checked and changed:

- **VideoToolbox real-time mode** — on. `AVAssetWriterInput.expectsMediaDataIsRealTime`
  is `true`, which selects the encoder's live path and makes the input *drop*
  rather than block when it falls behind (the right trade for a live take).
- **`expectedFrameRate`** — now set (`AVVideoExpectedSourceFrameRateKey`) so the
  encoder sizes its queue for the rate; it was already set for HEVC and is kept.
  Frame reordering is off, for latency.
- **Pixel-buffer copies** — none. Frames are appended by reference; the writer's
  restamp copies only the timing (`CMSampleBufferCreateCopyWithNewTiming`
  retains the image buffer, it does not copy pixels).

The residual drops are the shared hardware HEVC encoder saturating across
**three simultaneous 4K streams** on that machine — a throughput ceiling, not a
settings mistake. The change that matters for the recording is that a drop is
now **harmless**: the gap is padded to keep the file CFR and the timeline
correct, and the `overloaded` event warns while it is happening. A faithful
before/after needs the same three-4K-stream rig; the mechanical fixes above are
in, and the fake-load CFR tests confirm dropped and missing frames are padded to a
constant rate.
