# Changelog

What changed for people using Rheocles, release by release. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). Every release on GitHub carries its
section from this file, and the release workflow refuses to run without one.

## [Unreleased]

### Fixed

- A take that was prepared but never started no longer appears on disk at all. A paired recorder re-prepares its next take the moment you stop, so one manifest-only folder used to sit there between takes; a prepared take now lives in memory and is written only when recording actually starts.

## [0.1.2] — 2026-09-15

### Changed

- The status line at the foot of both apps says `local`, not `loopback` — the same fact, in the word the rest of the app uses.

### Fixed

- Arming and disarming no longer leave empty take folders. A paired recorder re-prepares its take on every arm change, and each abandoned one used to leave a folder holding only a manifest; a take that recorded nothing is now removed instead.
- The NativePHP app's logs no longer grow without bound. `~/Library/Logs/Rheocles/Rheocles-php.log` reached 2 GB when the terminal that launched the app went away and every console line became a logged exception; it now notes that once and goes quiet. Both it and the app's Laravel log are one file a day, three days kept, a day capped at 20 MB, and nothing is logged per pulse or per event.

## [0.1.1] — 2026-09-13

### Added

- Open in Finder buttons wherever a destination is shown: the finished take, each entry in the new Recent takes fold, the single file, and the output root in Settings. The daemon does the revealing (`POST /takes/{id}/reveal`, `POST /reveal`), so both apps get it the same way.
- "Also save a single file": with at most one video stream armed, a take can also be written as one `combined.mov` — the video with its timecode track and every audio stream as its own track, no re-encode and no mixdown. It is `settings.combine`, or `combine` on a single take; the manifest reports it as `combined` with `pending`, `complete` or `failed`, and a failed combine never marks the take itself incomplete.
- Combine now, on any finished take that qualifies but has no single file yet (`POST /takes/{id}/combine`).
- Recent takes: the last five, newest first, under the take bar in both apps.

### Changed

- The version the daemon reports — `GET /`, `--version`, and every manifest — comes from the build, so it always matches the app's own.
- A daemon whose screen source comes back empty now logs why, instead of silently listing no displays or windows.

### Fixed

- API responses carry millisecond timestamps, matching the manifest on disk; a marker's `t` no longer disagrees with the take's `started` by up to a second.
- Stream ids sent the way `encodeURIComponent` produces them (`display%3A…`) are accepted; they used to answer 404 while the bare colon worked.
- The menu bar app no longer briefly un-arms a switch while a stale streams read lands, and a take's single-file state can no longer be undone by a late answer.
- The NativePHP app keeps its own data under its own bundle id rather than in the daemon's directory.

## [0.1.0] — 2026-09-11

The first release. Rheocles records any number of input streams at once, each to its own file, on one cue.

### Added

- The `rheocles-core` daemon on `127.0.0.1:7447` (HTTP and SSE) and `7448` (WebSocket), behind a bearer token stored at `~/Library/Application Support/Rheocles/token`, with a pairing code and token rotation.
- Streams: every display (including screen-like devices such as the Elgato prompter), individual windows, cameras, microphones and system audio, listed by `GET /streams` and armed one at a time.
- Takes: create, start, stop and record on one cue; join and leave streams mid-take; markers; a `manifest.json` per take that is live while recording and truthful when a take ends early.
- Real files: HEVC (default) or ProRes 422 MOV with a time-of-day `tmcd` track and one-second fragments, and 48 kHz 24-bit Broadcast Wave with a `bext` time reference, so an editor syncs every file of a take by timecode in one click.
- Crash safety: a daemon stopped mid-take finalises it; a daemon that died leaves a manifest that says so and never serves that take as live; a full disk ends the take with the reason and playable partial files.
- Preview: an on-demand JPEG of any stream (`GET /preview/{stream}`) and live audio levels.
- Settings: output root and codec, over the API and in the apps; live events for streams, takes, levels, markers, stalls and settings on both transports.
- The menu bar app: streams with arm switches and permission nudges, Record and Stop, take name, elapsed time, markers, preview, levels, settings and pairing, in the site's limestone palette.
- The NativePHP front end, driving the same daemon — signed, not yet notarized, and not yet in the download.
- Signed and notarized DMG, a Homebrew cask (`brew install --cask artisan-build/tap/rheocles`), and [rheocles.com/docs](https://rheocles.com/docs) with an API reference generated from `docs/openapi.yaml`.

[Unreleased]: https://github.com/artisan-build/rheocles/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/artisan-build/rheocles/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/artisan-build/rheocles/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/artisan-build/rheocles/releases/tag/v0.1.0
