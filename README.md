# Rheocles

A macOS menu bar app that records **any number of input streams
simultaneously, each to its own file, on one cue** — cameras, microphones,
system audio, every display (including screen-like devices such as the Elgato
prompter), and individual windows. Arm what you want, hit record or have the
API do it, and every armed stream lands as its own file, stamped with
time-of-day timecode so an editor syncs them in one click. It exists because
OBS records one composited stream. Pteroprompter wants the camera, the
prompter screen, the mic and the system audio as separate files, started
together, with no compositor in the way. Sibling of
[Sonocles](https://github.com/artisan-build/sonocles).

The repo is a monorepo: `app/` is SwiftPM — `RheoclesCore`, the `rheocles-core`
daemon, and the `Rheocles` menu bar app; `php/` is the NativePHP front end;
`site/` is rheocles.com, built with Astro; `docs/` holds `PROTOCOL.md`,
`openapi.yaml`, `CAPTURE.md` and `BRAND.md`; `_tasks/` is deferred work,
written down; `.signing/` is gitignored certificate material for local signed
builds. CI mirrors Sonocles: tests on `app/**`, signed and notarized releases
on `v*` tags, site deploy on `site/**`.

**Status: pre-alpha, nothing ships yet.**
