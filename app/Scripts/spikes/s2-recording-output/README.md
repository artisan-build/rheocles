# Spike S2 — `SCRecordingOutput` and crash safety

**Question (spec §16).** Does `SCRecordingOutput` write a fragmented,
recoverable file? If not, do `SCStream` frames into our own `AVAssetWriter`
with `movieFragmentInterval`, and decide the mechanism for displays and
windows from the result.

**Verdict: displays and windows record through `SCStream` →
`AVCaptureVideoDataOutput`-style sample buffers → our `AVAssetWriter` with
`movieFragmentInterval`. `SCRecordingOutput` is not used.**

- `SCRecordingOutput` writes a **flat** movie (`ftyp wide mdat moov`, `moov`
  only at finalisation) and it does not write it from our process: the file
  is held and written by `/usr/libexec/replayd`. `kill -9` on our process
  therefore leaves a *playable* file — replayd finalises it after we die —
  but that is survival by proxy, not crash safety. Kill replayd instead
  (the stand-in for a power cut or a system crash) and the file is
  `ftyp wide mdat` with no `moov`: ffprobe "moov atom not found", AVAsset
  "Cannot Open, this media may be damaged". Our process was not even told;
  no delegate callback arrived. It also offers only `avc1`/`hvc1` (no
  ProRes) and no way to add a timecode track, both of which §8 needs.
- Our `AVAssetWriter` with `movieFragmentInterval = 1 s` writes
  `ftyp mdat moov [mdat moof]…` from the first second on, entirely in our
  process. `kill -9` at 12.5 s leaves a file with 11 `moof` boxes that
  ffmpeg decodes end to end and `AVAssetReader` reads back as 350 frames /
  12.08 s — at most the last fragment interval is lost. On a clean stop
  `finishWriting` rewrites it as a flat movie, so normal files stay
  maximally compatible and only crashed ones are fragmented.
- Window capture is the same path with `SCContentFilter(desktopIndependentWindow:)`;
  a 20 s window recording came back complete (584 frames). One trap: that
  filter asserts `CGS_REQUIRE_INIT` in a process that has never touched
  AppKit — `_ = NSApplication.shared` before any SCK call fixes it, and the
  daemon must do the same.

## Machine and setup

MacBook Pro (M1, 16 GB), macOS 26.6.2, Xcode 26.2, Swift 6.2.3. One display:
BenQ PD3220U, 3840×2160 @ 1× (`display 2`). The spike is a minimal signed
`.app` (`build.sh`: `S2.app`, bundle id `build.artisan.rheocles.spike.s2`,
`LSBackgroundOnly`, Developer ID Application: Artisan Build, Inc) launched
with `open --stdout … --stderr …`, so TCC attributes it to the bundle and
the Screen Recording grant survives rebuilds. The first launch returned
`SCStreamErrorDomain -3801 "The user declined TCCs"` while the system prompt
was up; Len granted it and every later launch preflights `true`.

## Method

`main.swift` builds to `S2.app/Contents/MacOS/s2`:

- `s2 rec-output --seconds N --out f.mov` — `SCStream` on the display with
  an `SCRecordingOutput` (`.mov`, HEVC).
- `s2 writer --seconds N --out f.mov [--fragment 1] [--window title]` —
  `SCStream` frames (420v, 30 fps cap, complete frames only) into
  `AVAssetWriter` (HEVC, `movieFragmentInterval` 1 s,
  `expectsMediaDataInRealTime`).
- `s2 probe f.mov` — `AVURLAsset` `isPlayable`/duration/tracks, then an
  `AVAssetReader` decode of every frame.

Both recorders log the file size once a second. `kill-test.sh MODE clean|kill`
launches the app, waits for `capture started`, and either lets it stop
itself at 20 s or sends `SIGKILL` at ~12.5 s, then reads the file back four
ways: `boxes.py` (top-level atom walk — `moof` present?), `ffprobe`,
`ffmpeg -f null -` (full decode), and `s2 probe` (AVFoundation).
`replayd-kill-test.sh` kills replayd instead of us. Logs and `*.verify.txt`
are committed under `out/`; the `.mov` files are not (103 MB).

`ffprobe`'s `nb_frames` on a fragmented file counts only the samples in
`moov` (29 here); the decoders count everything. Trust the decode.

## Raw output

### `SCRecordingOutput`, clean stop — `out/rec-output-clean.*`

```
[19:16:39.288] SCRecordingOutput added codec=hvc1 available=["avc1", "hvc1"] fileTypes=["public.mpeg-4", "com.apple.quicktime-movie"]
[19:16:39.596] SCRecordingOutput did start recording
[19:16:44.909] t=5 fileSize=5994131 frames=0 written=0
[19:16:50.236] t=10 fileSize=12112554 frames=0 written=0
[19:16:59.823] SCRecordingOutput did finish recording
--- boxes:
           0  ftyp             20
          20  wide              8
          28  mdat       21775686
    21775714  moov          10054
fragmented: no | has moov: yes
--- ffprobe: codec_name=hevc width=3840 height=2160 nb_frames=582 duration=20.163333
--- ffmpeg full decode: decode ok
[19:17:05.718]   AVAssetReader decoded 581 frames, last pts=20.135s status=2 (2 completed, 3 failed) error=none
```

### `SCRecordingOutput`, `kill -9` our process at 12.5 s — `out/rec-output-kill.*`

The file grew by 27 KB *after* our process was dead: someone else wrote the
`moov`.

```
--- kill -9 62489 at 19:17:23 (file size now 15518297)
=== rec-output-kill: 15545116 bytes
           0  ftyp             20
          20  wide              8
          28  mdat       15538212
    15538240  moov           6876
fragmented: no | has moov: yes
--- ffprobe: nb_frames=376 duration=12.835000
--- ffmpeg full decode: decode ok
[19:17:29.755]   AVAssetReader decoded 376 frames, last pts=12.833s status=2 (2 completed, 3 failed) error=none
```

Who: `out/lsof.txt`, taken during a recording —

```
COMMAND   PID   USER   FD   TYPE DEVICE SIZE/OFF      NODE NAME
replayd 34907 gopher   10u   REG   1,15  6792455 442522049 .../out/lsof.mov
spike pid=64553
```

### `SCRecordingOutput`, `kill -9 replayd` at 12.5 s — `out/rec-output-replayd-kill.*`

```
--- kill -9 replayd 34907 (/usr/libexec/replayd) at 19:21:31 (file size now 14645240)
--- our process 67560 alive: yes; killing it too
=== rec-output-replayd-kill: 14645240 bytes
           0  ftyp             20
          20  wide              8
          28  mdat       14645212
fragmented: no | has moov: no
--- ffprobe: moov atom not found / Invalid data found when processing input
--- ffmpeg full decode: Error opening input
[19:21:38.697] AVAsset load failed: Error Domain=AVFoundationErrorDomain Code=-11829 "Cannot Open" ... NSLocalizedFailureReason=This media may be damaged.
```

No `SCRecordingOutput` delegate callback reached our process in the 5 s
between killing replayd and killing ourselves.

### `AVAssetWriter`, clean stop — `out/writer-clean.*`

```
[19:20:32.xxx] AVAssetWriter started -> .../writer-clean.mov 3840x2160 hevc movieFragmentInterval=1.0s
[19:20:53.207] AVAssetWriter finished status=2 (2 completed, 3 failed) error=none frames=611 written=611 notReady=0
counts: {'ftyp': 1, 'wide': 1, 'mdat': 1, 'moov': 1}     <- flat again after finishWriting
fragmented: no | has moov: yes
--- ffprobe: nb_frames=611 duration=20.985000
--- ffmpeg full decode: decode ok
[19:20:59.402]   AVAssetReader decoded 611 frames, last pts=20.952s status=2 (2 completed, 3 failed) error=none
```

### `AVAssetWriter`, `kill -9` at 12.5 s — `out/writer-kill.*`

```
[19:18:18.727] AVAssetWriter started -> .../writer-kill.mov 3840x2160 hevc movieFragmentInterval=1.0s
--- kill -9 63797 at 19:18:31 (file size now 16287591)
=== writer-kill: 16287591 bytes                           <- unchanged after death
           0  ftyp             20
          20  wide              8
          28  mdat        1670233
     1670261  moov           1492
     1671753  wide              8
     1671761  mdat        1107644
     2779405  moof            528
     2779933  wide              8
     2779941  mdat         897295
     3677236  moof            592
         ...  (39 boxes total)
    15107999  moof            624
    15108623  wide              8
    15108631  mdat        1178960
counts: {'ftyp': 1, 'wide': 13, 'mdat': 13, 'moov': 1, 'moof': 11}
fragmented: yes | has moov: yes
--- ffprobe: nb_frames=29 duration=12.016667             <- nb_frames is the moov only
--- ffmpeg full decode: decode ok
[19:18:35.139] AVAsset .../writer-kill.mov: playable=true duration=12.117s tracks=1
[19:18:37.094]   AVAssetReader decoded 350 frames, last pts=12.083s status=2 (2 completed, 3 failed) error=none
```

### `AVAssetWriter`, window, clean — `out/window-clean.*`

```
[19:19:56.009] window 9565 'Solo' of Solo frame=(41.0, 39.0, 1852.0, 1684.0)
[19:20:16.373] AVAssetWriter finished status=2 (2 completed, 3 failed) error=none frames=584 written=584 notReady=0
--- ffprobe: width=1852 height=1684 nb_frames=584 duration=20.165000
[19:20:19.679]   AVAssetReader decoded 584 frames, last pts=20.132s status=2 (2 completed, 3 failed) error=none
```

## What this means for the build

1. **One writer for everything.** Cameras (S1), displays and windows (S2)
   all go sample buffer → `AVAssetWriter`. One `Writer` type in
   `RheoclesCore`, one fragment interval, one place to add the `tmcd` track
   (S3) and the ProRes alternative.
2. **Fragment interval is a real knob.** 1 s here; the loss window on a
   crash is at most one interval. The engine can expose it as a setting
   later; the default stays 1 s unless the HEVC tier measurement (task 4.9)
   shows a cost.
3. **A crashed file is fragmented and playable; a clean one is flat.** The
   manifest's `incomplete` state (§7) is the tell for downstream tools, and
   the file plays either way.
4. **Call `NSApplication.shared` (or otherwise connect to the window server)
   before ScreenCaptureKit** in `rheocles-core`, or window filters abort the
   daemon.
5. **Frame cadence on screens is content-driven.** SCK delivers a frame on
   change up to the cap (~29 fps observed on a busy desktop). The `tmcd`
   track and drift reporting (§9) must be based on presentation timestamps,
   not frame counts — noted for 4.5.

No spec change is required.
