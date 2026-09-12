---
title: Overview
description: Rheocles records every camera, microphone, display and window on your Mac at once, each to its own file, on one cue.
draft: true
---

Rheocles is a macOS menu bar app and a small HTTP API. You arm the streams you
want — cameras, microphones, every display, individual windows, system audio —
and on one cue every armed stream starts writing to its own file. Video lands
as QuickTime MOV with a time-of-day timecode track; audio lands as Broadcast
Wave with a matching time reference. An editor syncs them in one click, and
`manifest.json` in the take folder agrees with the files.

It exists because OBS records one composited stream, and
[Pteroprompter](https://pteroprompter.com) wanted the camera, the prompter
screen, the microphone and the system audio as separate files, started
together, with no compositor in the way.

## The shortest possible take

```sh title="three calls, one take"
# the token is provisioned to a file; no pairing dialog
TOKEN="$(cat ~/Library/Application\ Support/Rheocles/token)"
H="Authorization: Bearer $TOKEN"

curl -s -H "$H" -X POST localhost:7447/takes -d '{"name":"ep12"}'   # → id, paths. Not recording.
curl -s -H "$H" -X POST localhost:7447/takes/$ID/start              # the cue
curl -s -H "$H" -X POST localhost:7447/takes/$ID/stop
```

Every armed stream is now its own file under the output root, and the
manifest says so.

## Where to go next

The pages in the sidebar are in reading order. The two that make Rheocles
different from a compositor are **Streams and arming** — armed means live, and
a stream can join a take late — and **Timecode and sync** — every file carries
its own time.
