# Wire protocol

Every command is reachable over both transports, and every event reaches
both. One command table, two encoders: this document describes the table
once and the two encodings once.

**Status:** current with the code through task 4 step 8 — everything below is
live, and a contract test in CI validates every live response against
`openapi.yaml` on each push. Takes record real files (HEVC or ProRes MOV with a time-of-day `tmcd`
track and 1 s fragments, Broadcast Wave audio with a `bext` `TimeReference`);
join/leave/markers, live `levels`, `drift`, `stalled`, `settings`,
`token/rotate` and on-demand `preview` are all in. Sections marked *planned* describe what the next steps add and are
what the front ends build against; they change here before they change in
the code.

## Transports

| | endpoint | direction |
|---|---|---|
| HTTP + SSE | `http://127.0.0.1:7447` — commands as HTTP; events on `GET /events` | request/response + one-way stream |
| WebSocket | `ws://127.0.0.1:7448/` — commands as JSON frames; events as unsolicited frames | full duplex |

Both bind loopback only and both are up from the moment `rheocles-core`
starts, before any stream is armed or any take exists. They are not
alternatives: run both, always. A page reading SSE and a tool holding a
socket can want the same take at the same time.

## Authentication

A bearer token, always, on every transport. The daemon writes it to
`~/Library/Application Support/Rheocles/token` (mode 0600) on first launch;
any app running as the same user reads the file and is paired. Rotating the
token (from the UI, *planned* over the API) invalidates the old one on the
next request.

- **HTTP:** `Authorization: Bearer <token>` on every request, including
  `GET /`. Missing or wrong → `401` with the error shape below and
  `WWW-Authenticate: Bearer realm="Rheocles"`.
- **SSE:** `EventSource` cannot set headers, so `GET /events?access_token=<token>`
  is accepted as well (RFC 6750 §2.3). Loopback only, so the URL form exposes
  nothing a local page could not read from the header form.
- **WebSocket:** the first frame must be `{"auth": "<token>"}`, answered
  `{"id": null, "status": 200, "body": {"authenticated": true}}`. Until then
  every command is answered `401` and no event is delivered. A header on the
  upgrade would be the HTTP-shaped way, but a browser `WebSocket` cannot set
  one, so the frame is the one way that works everywhere and it is the only
  way.

## Commands

| route | does | since |
|---|---|---|
| `GET /` | discovery: name, version, hostname, machine id, output root, free bytes, auth mode, ports | step 1 |
| `GET /streams` | every stream with armed state, plus what macOS lets this process see | step 2 |
| `POST /streams/{id}/arm` | `{ "armed": true\|false }` — device live or not; never stamps, never writes | step 3 |
| `POST /streams/disarm` | disarm every armed stream at once; `409 take_active` while recording | prepared+disarm |
| `POST /takes` | prepare: snapshot the armed set, reserve paths, pre-flight the disk; the take lives in memory, nothing on disk until start | step 4 |
| `POST /takes/{id}/start` | the cue | step 4 |
| `POST /takes/{id}/stop` | finalize every writer and the manifest | step 4 |
| `POST /record` | create + start, the one-click form | step 4 |
| `GET /takes/{id}` | the manifest, live while recording | step 4 |
| `GET /takes` | recent takes, newest first | step 4 |
| `POST /takes/{id}/join` | `{ "stream": id }` — arms if needed, starts that stream's writer now | step 6 |
| `POST /takes/{id}/leave` | `{ "stream": id }` — finalizes that file; the stream stays armed | step 6 |
| `POST /takes/{id}/markers` | `{ "label": "…" }` → the manifest with the marker appended | step 6 |
| `GET /settings` | the daemon's output root, default codec and default combine | step 6 |
| `PATCH /settings` | `{ "outputRoot"?, "codec"?, "combine"? }` — change any | step 6 |
| `POST /takes/{id}/combine` | passthrough-mux a `complete`/`incomplete` take into `combined.mov` → the manifest (`combined` pending; completion on the `take` event) | reveal+combine |
| `POST /takes/{id}/reveal` | `{ "path"? }` — reveal the take folder (or a file in it) in the Finder; `204` | reveal+combine |
| `POST /reveal` | `{ "path"? }` — reveal any path under the output root in the Finder; `204` | reveal+combine |
| `POST /token/rotate` | `{}` → `{ "token" }` — new token, old one dead after the response | step 6 |
| `GET /preview/{stream}` | one preview frame on demand — JPEG for video, a JSON level for audio; one at a time | step 7 |

Paths in every response are relative to the output root, which `GET /`
reports as the one absolute path in the API.

### `GET /`

```json
{
  "name": "Rheocles",
  "version": "0.1.0",
  "hostname": "lens-macbook-pro.local",
  "machineId": "CD3B7EE5-5E6C-5155-854A-72E4728555F7",
  "outputRoot": "/Users/gopher/Movies/Rheocles",
  "freeBytes": 44878079167,
  "auth": "bearer",
  "ports": { "http": 7447, "ws": 7448 }
}
```

`freeBytes` is the volume's capacity for important usage at the output root
(or its nearest existing ancestor); it is **absent** when unmeasurable —
absent means unknown, never zero. `machineId` is the kernel host UUID,
stable across renames and reboots; both it and `hostname` go into every
manifest so a take stays legible after the machine is gone.

### `GET /streams`

```json
{
  "streams": [
    { "id": "display:56A96CFC-7F21-168E-0857-D6964E3302DB", "kind": "display",
      "name": "BenQ PD3220U", "model": "vendor 2513 model 32813",
      "capabilities": { "video": { "width": 3840, "height": 2160, "maxFrameRate": 60 } },
      "armed": false },
    { "id": "window:11597", "kind": "window",
      "name": "Google Chrome — Timecode and sync — Rheocles docs", "model": "com.google.Chrome",
      "capabilities": { "video": { "width": 1200, "height": 900, "maxFrameRate": 60 } },
      "armed": false },
    { "id": "camera:0x2300000fd9009c", "kind": "camera",
      "name": "Elgato 4K X", "model": "UVC Camera VendorID_4057 ProductID_156",
      "capabilities": { "video": { "width": 3840, "height": 2160, "maxFrameRate": 30 } },
      "armed": false },
    { "id": "microphone:AppleUSBAudioEngine_Focusrite_Scarlett_2i2_USB_Y8CABR91C1CA8A_1_2", "kind": "microphone",
      "name": "Scarlett 2i2 USB", "model": "Scarlett 2i2 USB:1235:8210",
      "capabilities": { "audio": { "sampleRate": 48000, "channels": 2 } },
      "armed": false },
    { "id": "systemAudio:system", "kind": "systemAudio",
      "name": "System audio", "model": "Core Audio tap",
      "capabilities": { "audio": { "sampleRate": 48000, "channels": 2 } },
      "armed": false }
  ],
  "permissions": { "camera": "notDetermined", "microphone": "authorized", "screen": "authorized" }
}
```

Order is fixed — displays, windows, cameras, microphones, system audio — so
the list is stable between calls even as devices come and go.

- **`id`** is stable and URL-safe: `<kind>:<identifier>` with the identifier
  reduced to `[A-Za-z0-9._-]`. Cameras and microphones use the device's
  unique id; displays their CoreGraphics UUID, which survives reconnects
  where the display number does not; windows their window number, which
  survives nothing and is not meant to. Clients hold ids; the manifest
  records `id`, `name` and `model` together (spec §5). An id in a path
  segment (`POST /streams/{id}/arm`, `GET /preview/{id}`) may be sent bare or
  percent-encoded — the colon as `%3A`, as `encodeURIComponent` produces —
  and the daemon decodes it either way, on both transports.
- **`kind`** is one of `display`, `window`, `camera`, `microphone`,
  `systemAudio`.
- **`capabilities.video`** is native pixels and the highest advertised rate.
  The signal's real rate can be lower (a 1080p30 HDMI source on a card that
  advertises 120); the writer follows the frames, not this field.
- **`capabilities.audio`** is the device's current sample rate and channel
  count. Recording is always 48 kHz 24-bit BWF regardless (spec §8).
- **`armed`** is whether the capture session is live (spec §6). Read here,
  changed by `POST /streams/{id}/arm`.
- **`active`** and **`framesSeen`** are present only while armed: the
  format the device is actually delivering (which is what a take records),
  and how many frames or audio buffers it has delivered since arming. A live
  device counts up; a stuck one does not.
- **`permissions`** is what macOS has let this process do — `authorized`,
  `denied`, `restricted` or `notDetermined`. Screen Recording gates displays
  and windows both: with `screen` anything but `authorized` the list simply
  has none, and this field is how a client tells "no displays" from "not
  allowed to see them". `notDetermined` means never asked; an app missing
  the entitlement never appears in System Settings at all (spec §4).

Windows are filtered to on-screen, titled, normal-layer windows of real
applications at least 64×64 points. The list is long and volatile by
nature; the popover hides it behind a setting (spec §5).

What each grant needs, verified on macOS 26.6 with the signed dev bundle
(spec §4 asked): camera — `NSCameraUsageDescription` +
`com.apple.security.device.camera`; microphone —
`NSMicrophoneUsageDescription` + `com.apple.security.device.audio-input`;
system audio — `NSAudioCaptureUsageDescription`, no further entitlement,
prompted as "System Audio Recording" on the first tap; screen and windows —
no key and no entitlement, ScreenCaptureKit prompts itself.

**Side effect:** the first `GET /streams` in a daemon process whose `screen`
permission is `notDetermined` raises the system's Screen Recording prompt,
once. Without the grant there are no displays to list, so there would be no
id to arm and nothing would ever ask; this is how every screen recorder
behaves on first launch. The grant takes effect on the daemon's next
launch.

**Dev launch caveat.** Run the daemon binary **bare from a shell** (not inside
the `.app`) and `GET /streams` lists windows, cameras and microphones but **no
displays** — and preview or arm of a screen source fails. A bare binary has no
AppKit run loop servicing the window-server connection that display enumeration
and `SCStream` capture need; `SCShareableContent`'s window list still comes
back, which is why windows appear but displays do not. The bundled app runs
that run loop, so a normally-launched daemon is unaffected. If a dev daemon
lists no displays, this is why — not a permission problem (`permissions.screen`
still reads `authorized`).

### `POST /streams/{id}/arm`

```json
→ { "armed": true }
← { "id": "camera:0x2300000fd9009c", "kind": "camera", "name": "Elgato 4K X", …,
    "armed": true,
    "active": { "video": { "width": 1280, "height": 720, "maxFrameRate": 120 } },
    "framesSeen": 0 }
```

Armed means the device is live (spec §6): the capture session runs and
frames flow and are discarded, so the cue starts a writer on frames that
already exist. Arming never stamps and never writes. Both directions are
idempotent and answer the stream as it now is. Disarming a joined stream
implies leave (step 6).

**Disarm all** — `POST /streams/disarm` — disarms every armed stream in one
call and answers the stream list, the same shape as `GET /streams`. The rig
stays armed after a take (armed means live — cameras on, CPU busy), and
switching four off one by one is a chore. It is **`409 take_active` while a
take is recording** — a take needs its streams, so stop it first. Each stream
that disarms emits its `stream` event as usual.

What arming holds, per kind:

- **camera** — an `AVCaptureSession` with the device's *current* format,
  and the configuration lock for the whole armed period (S1). Another app
  can still open the camera; it gets our format and cannot change it. The
  format at arm time is what is recorded, and `active` says what it is — a
  camera another app left at 720p stays at 720p until that app or the user
  changes it.
- **microphone** — an `AVCaptureSession` delivering 48 kHz 24-bit LPCM.
- **display / window** — an `SCStream` at the display's refresh rate,
  complete frames only (S2). A window that closes ends its session; the
  stream then reads as not armed.
- **systemAudio** — a Core Audio process tap on every process, clocked by
  the default output device. Needs the System Audio Recording grant, which
  macOS asks for on the first arm.

Errors: `404 not_found` for an unknown id, `403 permission_denied` when
macOS has not granted the device class (for camera and microphone the
prompt is raised first; `403` means it was refused), `503 device_unavailable`
when the device is gone, busy or refused the configuration.

Armed streams cost CPU and hold their devices. Five armed at once (a 4K
display, a window, a camera, a microphone, system audio) idle at roughly a
quarter of a core on an M1.

### Takes

The manifest is the take (spec §2, §9). `POST /takes` prepares it as
`state: created` and answers it, but keeps it **in memory** — nothing is
written to disk yet. `GET /takes/{id}`, the `take` event and the listing are
served from memory until start. The folder and `manifest.json` are written at
**start**, immediately before the first writer opens (still "before frame
one"), and every later state change rewrites the manifest atomically (temp
file + rename), so `manifest.json` is always either the previous complete
version or the next. A take prepared but never started therefore never touches
disk at all. Clients hold the id; every path in the answer is relative — the
take folder to the output root, each file to the take folder.

```json
→ POST /takes  { "name": "Episode 12", "expectedDuration": 3600 }
← 201 {
  "take": {
    "id": "20260912T040433-fd9q",
    "name": "Episode 12",
    "state": "created",
    "created": "2026-09-12T04:04:33.235Z",
    "outputRoot": "/Users/gopher/Movies/Rheocles",
    "destination": "takes/2026-09-11/210433-episode-12",
    "version": "0.1.0",
    "machine": { "hostname": "lens-macbook-pro.local", "machineId": "CD3B7EE5-…" },
    "streams": [
      { "id": "display:F65F9C53-…", "kind": "display", "name": "Prompter XL", "model": "vendor 9353 model 6433",
        "path": "prompter-xl.mov", "codec": "hevc",
        "format": { "video": { "width": 1920, "height": 1080, "maxFrameRate": 60 } },
        "framesWritten": 0, "events": [] },
      { "id": "microphone:…", "kind": "microphone", "name": "Scarlett 2i2 USB", "model": "Scarlett 2i2 USB:1235:8210",
        "path": "scarlett-2i2-usb.wav", "codec": "pcm_s24le",
        "format": { "audio": { "sampleRate": 48000, "channels": 2 } },
        "framesWritten": 0, "events": [] }
    ],
    "markers": [],
    "settings": { "codec": "hevc", "expectedDuration": 3600 }
  },
  "warnings": []
}
```

**Request fields**, all optional: `name`; `destination`, a folder relative
to the output root (default `takes/<yyyy-MM-dd>/<HHmmss>[-<name slug>]`,
local date and time); `files`, a map of stream id → file name relative to
the take folder (default: the stream's name slugged, `.mov` for video and
`.wav` for audio, `window-<bundle id>.mov` for windows, `-2`, `-3` on
collision); `codec`, `hevc` (default) or `prores`, one setting for the whole
take; `expectedDuration` in seconds for the pre-flight (default 1800);
`overwrite`; `combine`, whether to write a single `combined.mov` when the
take stops (default `settings.combine`).

**Rules**

- The armed set is snapshotted at create. Arming after create does not add
  a stream to the take; `join` (step 6) does.
- **Same destination twice → `409 conflict`** unless `overwrite: true`. A
  destination is taken if the folder exists and is not empty. Never
  silently suffixed.
- **Disk pre-flight**: the armed set's bitrates × `expectedDuration` are
  estimated (rough until step 9 measures the tiers); if free space is short
  → `507 insufficient_storage` and nothing is created; if it is under twice
  the estimate the take is created with a `warnings` line.
- **One active take.** While a take is `recording`, `POST /takes` and
  `POST /record` answer `409 take_active` naming it. A take that was created
  but never started is **superseded** by the next create. Since it lived in
  memory only — nothing on disk — superseding it touches no filesystem at all;
  a paired recorder re-preparing its take on every arm change leaves no trace.
  The `take` event for it is `incomplete`, reason `superseded before start`,
  with `removed: true` so a client drops it from its list.
- `POST /takes` with no armed streams is `400 bad_request`.
- Timestamps are UTC ISO 8601 with milliseconds; `t` values are seconds from
  the cue to the millisecond. The manifest is the authoritative clock across
  midnight (spec §8).

**Start** — `POST /takes/{id}/start` — is the cue. `started` is stamped,
every stream's writer starts on frames that are already flowing, each
stream gets `started` and a `{ "t": 0, "type": "join" }` event, and the
manifest reads `recording`. A stream that is no longer armed at the cue is
recorded with `error: "not armed at the cue"` and the take finishes
`incomplete`. `409` if the take is not `created`, or is not the active take.

**Stop** — `POST /takes/{id}/stop` — finalizes every writer, detaches it
from its stream (the stream stays armed), stamps `stopped`, fills
`timecode`, `framesWritten` and `drift` per stream, appends a `leave` event,
and writes the final manifest: `complete`, or `incomplete` with `reason`
listing every stream's error. `409` if the take is not `recording`.

**Record** — `POST /record` — is create followed by start in one call, with
the same body and answer as create.

**Combine ("Loom mode").** A take created with `combine: true` (or, by
default, while `settings.combine` is on) writes a single `combined.mov`
alongside the per-stream files when it stops. It is a **passthrough mux**, no
re-encode: the take's one video stream is copied as-is (with its time-of-day
`tmcd` track), and every audio stream becomes its own enabled track — no
mixdown, every source kept separate for the edit. A combine take may hold **at
most one video stream**; creating one with two or more is
`400 combine_requires_single_video`. A take with no video combines to an
audio-only `.mov`. The manifest gains
`combined: { "path": "combined.mov", "state": "pending" }` at create; when the
mux finishes after stop it flips to `complete` (or `failed` with a `reason`)
and a `take` event fires. A **failed combine never marks the take itself
incomplete** — the per-stream files are the take; the combined file is a
convenience. `POST /takes/{id}/combine` runs the same mux **after the fact** on
any take that is not the live take and qualifies — **`complete` or
`incomplete`** (a take that lost a stream is still worth a single file of
what it kept). It answers immediately with `combined.state: "pending"` and
fires the `take` event on completion, exactly like the post-stop path; a
second call while one is already pending is **idempotent** and returns the
pending manifest rather than racing a second mux. It is `409` while the take
is recording, `400 combine_requires_single_video` for more than one video,
and `400 nothing_to_combine` if the take has no files on disk. Joining a
second video into a live combine take is refused the same way. A combine left
`pending` by a daemon that died mid-mux is rewritten `failed` (`daemon died`)
on the next launch and its half-written file removed.

**Daemon lifecycle.** On **SIGINT/SIGTERM** the daemon finalizes an active
take — every writer closes and the manifest is written `incomplete` with
reason `daemon stopped` — so a cleanly-stopped daemon never leaves a take
saying `recording`. A take still `created` (never started) at shutdown lived
in memory only, so it simply disappears — a final `incomplete` /
`daemon stopped before start` event with `removed: true`, nothing on disk. On
**launch**, any manifest found `recording` or `created` on disk is from a
daemon that died without finalizing it (a crash, a `SIGKILL`, a power cut); a
`recording` one is rewritten `incomplete` with reason `daemon died`, and a
`created` one whose folder holds only the manifest — a stale one written by a
daemon predating in-memory prepared takes — is **removed**. A recovered take is
never served as the live take — a client that tries to `stop` or add a marker
to it gets `409`, and `GET /takes/{id}` already shows it `incomplete`.

**Read** — `GET /takes/{id}` answers the manifest at any time: live while
recording, from disk afterwards. `GET /takes` lists recent takes newest
first (the active one, then this process's finished ones, then whatever
the output root holds, up to 50). A take that has a combined file carries its
`combined` block in the summary too, so a list can show the single-file line
without a per-row fetch:

```json
[ { "id": "20260912T040433-fd9q", "name": "Episode 12", "state": "complete",
    "created": "2026-09-12T04:04:33.235Z", "destination": "takes/2026-09-11/210433-episode-12", "streams": 5,
    "combined": { "path": "combined.mov", "state": "complete" } } ]
```

### Join, leave, markers (spec §6, §10)

While a take is `recording`:

- **`POST /takes/{id}/join` `{ "stream": id }`** starts that stream's writer
  now and adds its file to the manifest, stamped with the time it actually
  began: a stream that joins four minutes in is stamped four minutes in, and
  an editor places it there. Join **arms the stream first if it is cold** —
  one call gets a cold stream into a running take. A stream that was in the
  create snapshot keeps its reserved path; a brand-new one gets a fresh name.
  `409` if the stream is already recording in the take.
- **`POST /takes/{id}/leave` `{ "stream": id }`** finalizes that stream's
  file and marks it complete; the stream **stays armed** and the take
  continues for the others. `409` if the stream is not recording in the take.
- **`POST /takes/{id}/markers` `{ "label": "…" }`** appends `{ t, label }` to
  the manifest, `t` in seconds from the cue. Rheocles owns the clock and
  stamps `t`; the client owns the label and Rheocles never interprets it.
  An empty label is `400`.

All three answer the updated manifest and are `409` outside a recording take.
Late joining is for saving CPU on a heavy stream you already know will not
need edit flexibility — arm everything you might want, record, and cut in the
edit. A script that toggles streams in and out mid-take has misunderstood the
tool.

### Settings (spec §12)

Daemon-owned defaults, persisted to
`~/Library/Application Support/Rheocles/settings.json`.

```json
GET /settings            → { "outputRoot": "/Users/gopher/Movies/Rheocles", "codec": "hevc", "combine": false }
PATCH /settings { "codec": "prores" }              → the full settings
PATCH /settings { "outputRoot": "/Volumes/SSD/Takes" } → the full settings
PATCH /settings { "combine": true }                → the full settings
```

`outputRoot` must be an absolute path, and it **cannot move while a take is
active** (`created` or `recording`) — its files are already reserved beneath
the old root — so that `PATCH` is `409`. `codec` is `hevc` or `prores` and is
the **default codec for new takes**: a take with no `codec` in its body
records in `settings.codec` (not a hardcoded HEVC). `combine` (default `false`) is the
**default combine for new takes** — a take with no `combine` in its body
follows it. Every change emits a `settings` event. `GET /` reports the same
output root.

Settings persist across launches. `rheocles-core --output-root DIR` is
authoritative when given — it overrides and re-persists the stored root —
otherwise the stored root (or `~/Movies/Rheocles` on first run) applies.

### Token rotation

```json
POST /token/rotate {}    → { "token": "9f3c…64 hex" }
```

Rewrites the token file and invalidates the old token for **every request
after this response** on both transports (a WebSocket that authenticated with
the old token stays up but must re-`auth` with the new one for later
commands). The pairing UI shows the new token; nothing else changes.

### Reveal in the Finder

```json
POST /takes/{id}/reveal { "path": "combined.mov" }   → 204
POST /takes/{id}/reveal {}                            → 204   (the take folder)
POST /reveal { "path": "takes/2026-09-11" }           → 204
POST /reveal {}                                        → 204   (the output root)
```

Both open a Finder window with the target selected, on the daemon's Mac —
this is a daemon-side action, since a browser front end cannot open the
Finder. `POST /takes/{id}/reveal` reveals the take's folder; an optional
`path` selects a file **within** it, relative to the folder.
`POST /reveal` reveals any path **under the output root**, relative to it;
an empty or omitted `path` reveals the root itself. `path` must stay within
its base — an absolute path or one that escapes with `..` is rejected — and
must exist: an unknown take or a `path` that names nothing is `404`. No body
on success (`204`).

### Preview (spec §12)

`GET /preview/{stream}` answers **one frame, on demand**. Nothing is captured
when nobody is looking: each request opens the device, grabs a single frame,
and closes it — and it opens as a **polite second opener** (no configuration
lock, no format change), so previewing a camera or screen that a take is
recording never disturbs the take. One preview runs at a time.

- **Video** (display, window, camera) → `image/jpeg`, longest side 640.
- **Audio** (microphone, system audio) → `application/json`
  `{ "levelDb": <peak dBFS of a short sample> }`, for the popover's meter.
  The level is read with the same format-aware path as the writer, so a
  device's 24-in-32 / packed-24 / float layout reads correctly rather than as
  full scale.

`404` for an unknown stream; `503 no_frame` if the device delivered no frame
(a camera with no signal). Over WebSocket the JPEG comes back as `base64`
with its `contentType` (see below), since a JSON frame cannot carry raw bytes.

### Files and clocks

Every armed stream lands as its own file, started on the cue and stamped so
an editor syncs them with no manifest (spec §4, §8).

- **Video** (displays, windows, cameras) → QuickTime MOV, **HEVC** by
  default or **ProRes 422** (`settings.codec`, one setting for the whole
  take), written with a 1 s `movieFragmentInterval` so a crash leaves a
  playable file, plus a **`tmcd` timecode track**. The HEVC default is
  **0.15 bits per pixel per frame** — the decided tier, measured visually
  transparent versus ProRes 422 at 1080p and 4K (`docs/CAPTURE.md`).
- **Audio** (microphones, system audio) → **Broadcast Wave**, 48 kHz 24-bit
  LPCM, separate files, with a `bext` chunk. Video files carry no audio.
- **`timecode`** is the file's start timecode as `HH:MM:SS:FF` — the
  **local time of day** (the machine's own midnight) of the first written
  frame, rounded to the nearest frame. It counts at the integer frame rate
  (59.94 and 60.00024 both count in 60; the file's frame timing carries the
  exact rate).
- **`timeReference`** (audio only) is the BWF `TimeReference`: samples since
  **local** midnight at the first sample — the sample-exact form of the same
  time of day.
- **The manifest's `created`, `started`, `stopped` are UTC** ISO 8601 with
  milliseconds; `t` values are seconds from the cue. Across midnight the
  manifest is authoritative: a file that started before midnight and a file
  that joined after disagree by 24 h in timecode, but the manifest's UTC
  times do not (spec §8).
- **Video is written at a constant frame rate.** Every frame is stamped by
  the host clock at capture — the clock the audio, `started` and `tmcd` share
  — and snapped to a nominal-rate grid; a **short** gap (a slow source, or a
  dropped frame) is filled with the last frame so the run stays constant-rate
  and no NLE has to conform VFR, while a **long** hold (a static screen, a
  stalled source, a saturated encoder) is carried as a held frame at the
  correct time rather than a burst of duplicates. Either way the timeline is
  the host clock's, so video never slips against audio the way a "60" card fed
  a 59.94 signal used to (half a second over seven minutes), and a static tail
  is spanned to stop.
- **`framesWritten`** counts frames actually in the file (real plus padding
  for video) or samples (audio); **`framesDropped`** (video, absent when zero)
  counts frames the encoder was not ready for under load — the gap is padded
  or held, so the timeline stays correct.
- **`measuredFrameRate`** (video) is the true incoming rate — delivered frames
  over the host span — so a 59.94 source behind a "60" card reads 59.94, the
  nominal notwithstanding.
- **`drift`** is delivered frames × nominal frame duration versus the
  timeline they span, in seconds: ~0 for a camera at its rate, negative for
  a capture card fed a slower signal. It is now **measured and corrected** —
  the CFR grid removes the slip — and reported for the record. It is **absent
  for displays and windows**, whose cadence is content-driven and where drift
  is meaningless. Audio `drift` is samples ÷ rate versus host elapsed.

A stream that delivered no frames while armed writes no file and finishes
the take `incomplete` with a per-stream `error` (`no frames arrived`) — a
camera with the lid closed, say. Its live `framesSeen` in `GET /streams`
stays 0 while armed, which is the signal a client watches. Screens deliver a
frame only when the content changes; a ~1 fps keepalive re-feeds the last
frame so a static screen (a prompter holding a page) still spans the take
and still flushes fragments, so it too is crash-recoverable.

## Encodings

### HTTP

JSON in (`Content-Type: application/json`, `Content-Length` required), JSON
out, keys sorted, `Connection: close`. CORS is open (`*`) so a page in the
user's browser can call the API — the token is the lock, not the origin.
`OPTIONS` on any path answers `204`.

### WebSocket

Text frames, one JSON object each.

```json
→ { "id": 7, "method": "GET", "path": "/", "query": {}, "body": null }
← { "id": 7, "status": 200, "body": { "name": "Rheocles", … } }
```

`id` is anything the client likes (number, string, or omitted → `null`) and
is echoed back untouched; `method`, `path` and the optional `query` and
`body` are exactly the HTTP request's. `status` is the HTTP status the same
command would have produced. Events (*planned*, step 6) arrive on the same
socket as objects with an `event` key and no `id`.

### Errors

One shape, on every route and both transports:

```json
{ "error": "no such route", "code": "not_found" }
```

`error` is for humans; `code` is stable and for programs. HTTP carries the
status in the status line, WebSocket in the frame's `status`.

| status | code | when |
|---|---|---|
| 400 | `bad_request` | malformed JSON, missing body, a frame without `method`/`path` |
| 401 | `unauthorized` | no token, wrong token, WebSocket before the auth frame |
| 403 | `permission_denied` | macOS has not granted the device class this stream needs |
| 404 | `not_found` | no such route or stream; *planned*: no such take |
| 405 | `method_not_allowed` | the path exists, the method does not; the message names what would |
| 409 | `conflict` | destination already exists; a take is not in the state the verb needs |
| 409 | `take_active` | a take is recording; stop it first |
| 400 | `combine_requires_single_video` | a combine take may hold at most one video stream |
| 400 | `nothing_to_combine` | `POST /takes/{id}/combine` on a take with no files on disk |
| 500 | `internal` | a handler threw something that is not an `APIError` |
| 501 | `unsupported` | this kind cannot be captured yet |
| 503 | `device_unavailable` | the device is gone, busy, or refused the configuration |
| 507 | `insufficient_storage` | the disk pre-flight refused the take |

## Events

`GET /events` is SSE: `data: <json>\n\n` per event, `: connected` on open.
The same objects, byte for byte, go to every authenticated WebSocket client.
Every event has an `event` key naming its kind and no `id`.

| event | since | carries |
|---|---|---|
| `stream` | step 3 | `stream`: the `StreamInfo` as it now is, on every change of armed state |
| `take` | step 4 | `take`: the manifest, on every state change (`created`, `recording`, `complete`, `incomplete`) and when a `combined` mux finishes — carries join/leave events and markers; `removed: true` on the final event for a take that recorded nothing and was discarded (superseded before start, or `created` at shutdown) — a prepared take never reaches disk |
| `levels` | step 6 | `take` id and `streams: [{ id, levelDb?, framesWritten, drift?, framesDropped?, measuredFrameRate? }]`, ~4×/s while recording — meters, a live drift readout, the drop count and the true rate. `levelDb` is peak dBFS since the last event, audio only |
| `marker` | step 6 | `take` id and the `{ t, label }` just added |
| `stalled` | step 6 | `stream`: an armed or recording stream that stopped delivering frames (a camera with the lid closed) |
| `overloaded` | drift+cfr | `stream` and `dropRate`: a recording stream dropping more than ~5% of frames over the last 10 s — the encoder cannot keep up. The file stays constant-rate; the footage is degraded |
| `settings` | step 6 | `settings`: the new `{ outputRoot, codec, combine }` |

```json
{ "event": "stream",   "stream": { "id": "microphone:…", "kind": "microphone", "armed": true, "active": { … }, "framesSeen": 0, … } }
{ "event": "levels",   "take": "20260912T045007-5kqn", "streams": [ { "id": "camera:…", "levelDb": null, "framesWritten": 24000, "drift": -0.5, "framesDropped": 3916, "measuredFrameRate": 59.94 } ] }
{ "event": "marker",   "take": "20260912T045007-5kqn", "marker": { "t": 2.042, "label": "chapter 1" } }
{ "event": "stalled",  "stream": { "id": "camera:…", "kind": "camera", "armed": true, "active": { … }, "framesSeen": 0, … } }
{ "event": "overloaded", "stream": { "id": "camera:…", "kind": "camera", "armed": true, "active": { … }, "framesSeen": 24000, … }, "dropRate": 0.16 }
{ "event": "settings", "settings": { "outputRoot": "/Users/gopher/Movies/Rheocles", "codec": "prores", "combine": false } }
```

## Consuming it

```bash
TOKEN=$(cat ~/Library/Application\ Support/Rheocles/token)
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7447/
```

```js
const token = /* read the token file, or the pairing code from the UI */
const ws = new WebSocket('ws://127.0.0.1:7448/')
ws.onopen = () => ws.send(JSON.stringify({ auth: token }))
ws.onmessage = (e) => handle(JSON.parse(e.data))
ws.send(JSON.stringify({ id: 1, method: 'GET', path: '/' }))

const es = new EventSource(`http://127.0.0.1:7447/events?access_token=${token}`)
es.onmessage = (e) => handle(JSON.parse(e.data))
```
