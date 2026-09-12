# Spike S1 — camera sharing

**Question (spec §16).** Can two processes hold one camera on this macOS, one
of them Rheocles recording while another app previews or records, without
either losing frames? If yes, the virtual camera is out of scope for good.

**Verdict: holds, with one condition.** Two processes share a camera freely —
the second open always succeeds, in either order, and with the same
configuration on both sides neither drops a frame. But the device's format is
owned by whoever configured it last: a second opener that asks for a different
resolution or frame rate *silently* changes what the first opener receives,
mid-recording, with a ~0.7 s stall at the handover and no KVO in the first
process. Holding `AVCaptureDevice.lockForConfiguration()` for the whole armed
period prevents that entirely: the other app still opens the camera, still
records, and simply gets our format. **Rheocles arms with the configuration
lock held. The virtual camera is not built.**

Second finding, for the S2/§8 design: `AVCaptureMovieFileOutput` stops writing
the instant the device is reconfigured under it and never calls
`didFinishRecording` — the file it leaves is truncated to the handover
(5.4 s of a 40 s take). Our own `AVAssetWriter` fed from
`AVCaptureVideoDataOutput` kept every frame. QuickTime Player, which uses the
movie file output, suffered the same truncation when *we* were the second
opener (9.2 s file of a 27 s recording). We write with our own writer.

## Machine

MacBook Pro (M1, 16 GB), macOS 26.6.2, Xcode 26.2, Swift 6.2.3. Camera under
test: **Elgato 4K X** (UVC, `VendorID_4057 ProductID_156`), fed by a real
1080p camera over HDMI. Second app: **QuickTime Player** (macOS 26), *File →
New Movie Recording*, which on this machine has the Elgato 4K X selected as
its camera (read from its device menu with System Events; see
`quicktime.applescript`). The FaceTime HD camera delivered zero frames in
the one attempt made (`AVCaptureMovieFileOutput` reported `-11805 Cannot
Record`) — probably the lid is closed on an external display; not chased,
since the Elgato is the camera that matters. `out/mine-first-locked-facetime/`
is that attempt; its QuickTime camera-menu click also misfired, so it proves
nothing either way.

## Method

`main.swift` builds to `s1` (`./build.sh`; an `Info.plist` with
`NSCameraUsageDescription` is embedded in the binary). `s1 run` opens the
device in an `AVCaptureSession` with:

- an `AVCaptureVideoDataOutput` (`alwaysDiscardsLateVideoFrames = false`) that
  counts every frame and every `didDrop`, logs any change in delivered frame
  dimensions, and records inter-frame gaps from presentation timestamps, so a
  device-side stall shows as a gap even when nothing is "dropped";
- an `AVCaptureMovieFileOutput` writing `*-fileoutput.mov`;
- our own `AVAssetWriter` (H.264, `movieFragmentInterval` 1 s) fed from the
  data output, writing `*-assetwriter.mov`;
- KVO on `isInUseByAnotherApplication` and `activeFormat`, and observers for
  every `AVCaptureSession` interruption/error notification;
- `--hold-lock`: `lockForConfiguration()` held for the whole run.

One status line per second; a SUMMARY at the end; every file read back with
`ffprobe`. Runs:

| script | order | lock | out/ |
|---|---|---|---|
| `test-mine-first.sh` | spike first, QuickTime joins at ~7 s and records 20 s | no | `mine-first/` |
| `test-mine-first-locked.sh` | same | **yes** | `mine-first-locked/` |
| `test-theirs-first.sh` | QuickTime first, spike joins at ~11 s and records 25 s | no | `theirs-first/` |
| `test-two-spikes.sh` | spike first, a second spike joins at ~8 s | no | `two-spikes/` |

Logs (`mine.log`, `first.log`, `second.log`, `quicktime.log`, `ffprobe.txt`)
are committed under `out/`; the `.mov` files are not (560 MB).

**TCC.** A bare executable's camera request is attributed to the process
that launched it. Run from the agent's shell (host: Solo.app, which has no
`NSCameraUsageDescription`) the request is refused in 15 ms with no prompt —
status stays `notDetermined`:

```
[19:05:13.303] camera authorization status: 0 (0 notDetermined, 1 restricted, 2 denied, 3 authorized)
[19:05:13.308] requesting camera access — a TCC prompt should appear on the host app now
[19:05:13.323] camera access granted: false
```

Run from Apple Terminal the prompt appeared for Terminal and Len granted it
(`18:44:04.193 camera access granted: true`); every run below was launched in
a Terminal window (`in-terminal.sh`) for that reason. `osascript → System
Events` needs Accessibility, which the agent host has and Terminal does not,
so QuickTime was driven from the agent's shell while the spike ran under
Terminal. This is the spike's arrangement only; the product is a signed
bundle with its own TCC identity (spec §4).

## Raw output

### A. Ours first, no lock — `out/mine-first/`

QuickTime opened the camera at 18:59:01. Our delivered frames went from
1920×1080 @ 30 to **1280×720 @ 120**, with a 0.73 s gap. No `activeFormat`
KVO, no session notification, `isInUseByAnotherApplication` never left
`false`.

```
[18:58:54.878] [mine] opening: Elgato 4K X | ... | 1280x720@120.00048000192001 420v | inUseByOther=false
[18:58:54.955] [mine] activeFormat changed -> Elgato 4K X | ... | 1920x1080@120.00048000192001 420v
[18:58:55.543] frame dimensions now 1920x1080
[18:58:55.696] writer started -> .../mine-first/mine-assetwriter.mov 1920x1080
[18:58:55.914] recording started -> .../mine-first/mine-fileoutput.mov
[18:59:00.061] [mine] t= 5 frames=  136 (+ 30) drops=0 medianGap=0.0334s maxGap=0.0989s stalls=1
[18:59:01.066] [mine] t= 6 frames=  166 (+ 30) drops=0 medianGap=0.0334s maxGap=0.0989s stalls=1
[18:59:01.985] frame dimensions now 1280x720
[18:59:02.071] [mine] t= 7 frames=  183 (+ 17) drops=0 medianGap=0.0334s maxGap=0.7251s stalls=3
[18:59:03.076] [mine] t= 8 frames=  300 (+117) drops=0 medianGap=0.0333s maxGap=0.7251s stalls=3
[18:59:04.082] [mine] t= 9 frames=  421 (+121) drops=0 medianGap=0.0084s maxGap=0.7251s stalls=173
...
[18:59:40.280] movie file output never reported didFinishRecording within 5s
[18:59:40.317] writer finished status=2 (2 completed, 3 failed) error=none frames=4764 notReady=0
[18:59:40.511] [mine] SUMMARY device=Elgato 4K X seconds=45.5 frames=4771 avgFps=104.92 medianGap=0.0083s (120.0 fps) drops=0 [:] maxGap=0.7251s stalls=174 recordingErrors=[]
```

```
--- ffprobe out/mine-first/mine-assetwriter.mov:   nb_frames=4764  duration=44.826667   (1920x1080 container; content is upscaled 720p after 7 s)
--- ffprobe out/mine-first/mine-fileoutput.mov:    nb_frames=165   duration=5.405100    (truncated at the handover)
--- ffprobe out/mine-first/quicktime.mov:          1280x720 r_frame_rate=120/1 nb_frames=2391 duration=19.019709
```

### A′. Ours first, lock held — `out/mine-first-locked/`

Same sequence with `--hold-lock`. QuickTime opened and recorded 19 s; our
stream did not change: 1080p30 throughout, no stall, both of our files
complete.

```
[19:00:31.738] [mine] holding lockForConfiguration for the run
[19:00:32.241] frame dimensions now 1920x1080
[19:00:36.766] [mine] t= 5 frames=  136 (+ 30) drops=0 medianGap=0.0334s maxGap=0.0991s stalls=1
[19:00:37.769] [mine] t= 6 frames=  166 (+ 30) drops=0 medianGap=0.0334s maxGap=0.0991s stalls=1   <- QuickTime opens here
[19:00:38.772] [mine] t= 7 frames=  196 (+ 30) drops=0 medianGap=0.0334s maxGap=0.0991s stalls=1
...
[19:01:16.986] writer finished status=2 (2 completed, 3 failed) error=none frames=1341 notReady=0
[19:01:17.182] [mine] SUMMARY device=Elgato 4K X seconds=45.4 frames=1342 avgFps=29.53 medianGap=0.0334s (30.0 fps) drops=0 [:] maxGap=0.0991s stalls=1 recordingErrors=[]
```

```
--- ffprobe out/mine-first-locked/mine-assetwriter.mov:  nb_frames=1341  duration=44.810000
--- ffprobe out/mine-first-locked/mine-fileoutput.mov:   nb_frames=1181  duration=39.305033
--- ffprobe out/mine-first-locked/quicktime.mov:         1280x720 r_frame_rate=30000/1001 nb_frames=599 duration=19.068833
```

(The one `stalls=1` / `maxGap=0.099` in every run is the first frame after
session start, before any second process exists.) QuickTime got our 30 fps
rather than its usual 120 — the lock works in both directions.

### B. QuickTime first, no lock — `out/theirs-first/`

QuickTime was recording at 720p120 when we opened. Our open succeeded and our
session set 1080p30; we recorded 25 s clean. QuickTime's recording stopped
receiving video at that moment: its window later showed a 27 s recording,
the saved file holds 9.2 s. Its document reference also went stale, which is
why `quicktime.log` shows `Can't get document "Movie Recording"` and the file
was saved by hand afterwards.

```
[19:02:01.933] [mine] opening: Elgato 4K X | ... | 1280x720@120.00048000192001 420v
[19:02:02.124] [mine] activeFormat changed -> Elgato 4K X | ... | 1920x1080@120.00048000192001 420v
[19:02:03.097] frame dimensions now 1920x1080
[19:02:32.913] [mine] SUMMARY device=Elgato 4K X seconds=30.4 frames=889 avgFps=29.25 medianGap=0.0334s (30.0 fps) drops=0 [:] maxGap=0.0993s stalls=1 recordingErrors=[]
```

```
--- ffprobe out/theirs-first/mine-assetwriter.mov:  nb_frames=887  duration=29.663333
--- ffprobe out/theirs-first/mine-fileoutput.mov:   nb_frames=728  duration=24.190867
--- ffprobe out/theirs-first/quicktime.mov:         1280x720 r_frame_rate=120/1 nb_frames=1214 duration=9.217271
```

### C. Two spikes, same configuration, no lock — `out/two-spikes/`

The control: a second process with the same format asks for nothing new.
Both sides 30 fps, zero drops, zero stalls, every file complete.

```
[19:03:51.972] [first]  SUMMARY device=Elgato 4K X seconds=35.4 frames=1041 avgFps=29.42 medianGap=0.0334s (30.0 fps) drops=0 [:] maxGap=0.0993s stalls=1 recordingErrors=[]
[19:03:39.990] [second] SUMMARY device=Elgato 4K X seconds=15.2 frames=453  avgFps=29.88 medianGap=0.0334s (30.0 fps) drops=0 [:] maxGap=0.0340s stalls=0 recordingErrors=[]
```

```
--- ffprobe out/two-spikes/first-assetwriter.mov:   nb_frames=1040 duration=34.763333
--- ffprobe out/two-spikes/first-fileoutput.mov:    nb_frames=881  duration=29.295500
--- ffprobe out/two-spikes/second-assetwriter.mov:  nb_frames=445  duration=15.081667
```

## What this means for the build

1. **No virtual camera.** Sharing works at the OS level; §17's "virtual
   camera (pending S1)" becomes "not needed".
2. **Arm = open the device, choose the format, and hold
   `lockForConfiguration()` until disarm.** That is what makes "armed means
   the device is live" survive someone opening Photo Booth mid-take. Document
   the consequence: while a stream is armed, other apps get Rheocles' format.
3. **Cameras record through `AVCaptureVideoDataOutput` → our
   `AVAssetWriter`**, never `AVCaptureMovieFileOutput`. This also lines up
   with the timecode track (S3) and fragment interval (§8), which the movie
   file output cannot do.
4. **Watch delivered frame dimensions, not `activeFormat`.** The reliable
   signal that the device changed under us is the format description on the
   sample buffer; `activeFormat` KVO and `isInUseByAnotherApplication` said
   nothing during any of these runs. The engine should log a format change on
   a recording stream as an error event and record it in the manifest.
5. **Be a polite second opener.** When arming a device another app already
   has open, prefer `sessionPreset = .inputPriority` and keep the device's
   current format if it is usable, since forcing ours truncates their
   recording the way theirs would truncate ours. Not a spike question; a
   design note for task 4.2.
6. **Native rate needs care.** The 4K X advertises 1080p120 and duplicates
   frames to whatever rate is requested; the HDMI source is 30 fps. "Native"
   must mean the signal's rate, not the format's maximum. Task 4.5.

No spec change is required. Item 5 of the arming design is new and is a
recommendation, not a decision.
