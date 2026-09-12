# Wire protocol

Every command is reachable over both transports, and every event reaches
both. One command table, two encoders: this document describes the table
once and the two encodings once.

**Status:** current with the code through task 4 step 1 (`GET /`, auth,
framing). Sections marked *planned* describe what the next steps add and are
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
| `GET /streams` | every stream with armed state | *planned*, step 2 |
| `POST /streams/{id}/arm` | `{ "armed": true\|false }` — device live or not; never stamps, never writes | *planned*, step 3 |
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
| 404 | `not_found` | no such route; *planned*: no such stream or take |
| 405 | `method_not_allowed` | the path exists, the method does not; the message names what would |
| 409 | `conflict` | *planned*: destination already exists, a take already active |
| 500 | `internal` | a handler threw something that is not an `APIError` |
| 507 | `insufficient_storage` | *planned*: disk pre-flight refused the take |

## Events (*planned*, step 6)

`GET /events` is SSE: `data: <json>\n\n` per event, `: connected` on open.
The same objects go to every authenticated WebSocket client. Kinds: `state`,
`levels`, `drift`, `join`, `leave`, `marker`, `error`. Shapes land here
before step 6 ships.

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
