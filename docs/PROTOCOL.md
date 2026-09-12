# Wire protocol

Every command is reachable over both transports, and every event reaches
both. One command table, two encoders: this document describes the table
once and the two encodings once.

**Status:** current with the code through task 4 step 3 (`GET /`, auth,
framing, `GET /streams`, arm/disarm, the `stream` event). Sections marked *planned* describe what the next steps add and are
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
| `POST /takes` | create: snapshot the armed set, reserve paths, write the manifest; nothing records | *planned*, step 4 |
| `POST /takes/{id}/start` | the cue | *planned*, step 4 |
| `POST /takes/{id}/stop` | finalize every writer and the manifest | *planned*, step 4 |
| `POST /record` | create + start, the one-click form | *planned*, step 4 |
| `GET /takes/{id}` | the manifest, live while recording | *planned*, step 4 |
| `GET /takes` | recent takes | *planned*, step 4 |
| `POST /takes/{id}/join` | `{ "stream": id }` — arms if needed, starts that stream's writer now | *planned*, step 6 |
| `POST /takes/{id}/leave` | `{ "stream": id }` — finalizes that file; the stream stays armed | *planned*, step 6 |
| `POST /takes/{id}/markers` | `{ "label": "…" }` → `{ "t": seconds from the cue, "label" }` | *planned*, step 6 |
| `GET /preview/{stream}` | one low-rate preview frame; one stream at a time | *planned*, step 7 |

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
  records `id`, `name` and `model` together (spec §5).
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

**Side effect:** the first `GET /streams` in a daemon process whose `screen`
permission is `notDetermined` raises the system's Screen Recording prompt,
once. Without the grant there are no displays to list, so there would be no
id to arm and nothing would ever ask; this is how every screen recorder
behaves on first launch. The grant takes effect on the daemon's next
launch.

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
| 409 | `conflict` | *planned*: destination already exists, a take already active |
| 500 | `internal` | a handler threw something that is not an `APIError` |
| 501 | `unsupported` | this kind cannot be captured yet |
| 503 | `device_unavailable` | the device is gone, busy, or refused the configuration |
| 507 | `insufficient_storage` | *planned*: disk pre-flight refused the take |

## Events

`GET /events` is SSE: `data: <json>\n\n` per event, `: connected` on open.
The same objects, byte for byte, go to every authenticated WebSocket client.
Every event has an `event` key naming its kind and no `id`.

| event | since | carries |
|---|---|---|
| `stream` | step 3 | `stream`: the `StreamInfo` as it now is, on every change of armed state |
| `state`, `levels`, `drift`, `join`, `leave`, `marker`, `error` | *planned*, step 6 | shapes land here before step 6 ships |

```json
{ "event": "stream", "stream": { "id": "microphone:…", "kind": "microphone", "armed": true, "active": { … }, "framesSeen": 0, … } }
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
