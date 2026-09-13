# Rheocles for NativePHP

The NativePHP front end: the same popover as the Swift menu bar app, in
Laravel + Electron, driving the same `rheocles-core` daemon over the same
API (`docs/PROTOCOL.md`, `docs/openapi.yaml`). It bundles its own copy of the
core as a sidecar and launches it on demand; two front ends on one machine
share one core. Destined to be lifted whole into Pteroprompter.

Nothing about capture happens here. AVFoundation and ScreenCaptureKit are
not reachable from PHP; "feature complete" means the UI (spec §13).

## The shape

```
Rheocles.app  (Electron + static PHP)
├── menu bar icon ........ MenuBar::create(), template PNGs per state, no Dock icon
├── rheo:watch ........... one ChildProcess for the life of the app: finds or
│                          launches the core, follows GET /events, sets the icon,
│                          publishes the daemon's state for the popover
├── popover .............. Blade + vanilla JS; holds its own EventSource and
│                          reads GET / from the daemon directly on a 3 s pulse
│     └── clicks ......... fetch → Laravel → 127.0.0.1:7447 (human speed)
└── Contents/extras/rheocles-core   the daemon, spawned as a ChildProcess
```

**PHP is not in the frame path.** The web view holds the event stream itself;
PHP carries clicks and the pulse. This is Sonocles' load-bearing decision
(`sonocles/php/FEASIBILITY.md`) and it is kept.

| | |
|---|---|
| `app/Rheocles/Daemon.php` | the lifecycle (spec §3): probe → use / launch, crash guard, quit only kills ours |
| `app/Rheocles/Client.php` | the HTTP transport, one method per route, the protocol's one error shape |
| `app/Rheocles/EventStream.php` | `GET /events` as PHP reads it — the watcher's copy, not the popover's |
| `app/Rheocles/IconState.php` | what the icon says, from what the daemon says |
| `app/Console/Commands/Watch.php` | `rheo:watch` |
| `app/Rheocles/Preferences.php` | show windows, in NativePHP's `Settings`; the codec and the root are the daemon's |
| `resources/views/menubar.blade.php`, `public/popover.css`, `public/js/` | the popover; `state.js` is the pure part |
| `resources/menubar/` | the icon, every state, from `bin/make-icons.swift` |
| `nativephp/electron/build/entitlements.mac.plist` | camera + audio-input, which NativePHP does not scaffold |
| `nativephp/electron/electron-builder.mjs` | the three usage strings, `LSUIElement` |
| `nativephp/electron/build/notarize.js` | fails on failure; the scaffold did not |
| `extras/rheocles-core` | the sidecar (build product, not committed) |

## Running it

```bash
cd php
composer install
(cd nativephp/electron && npm run plugin:build)    # see note
swift build --package-path ../app -c release       # the core
bin/sync-sidecar.sh                                # copy it into extras/
bin/dev-run.sh                                     # the app, on the desktop
bin/dev-stop.sh                                    # …and off again
```

`dev-run.sh` is `native:run -v` in the background with its output in a file
(without `-v` there is none), after clearing compiled views — NativePHP
seeds the app's data directory from `storage/` at every launch, and a stale
compiled view there shadows the source. `dev-stop.sh` stops the app through
Electron so its children go with it; killing `native:run` instead leaves
Electron writing to a closed stdout, one `EPIPE` per line. ⌘R in the
popover reloads its page.

**`plugin:build` is not optional.** NativePHP 2.3.0 publishes an
`electron-plugin/dist` missing `server/pdfPageSize.js`; without rebuilding
the plugin `native:run` prints a success line and then dies on
`No electron app entry file found`.

In development the daemon runs on **7467/7468** (`.env`); `:7447` belongs to
whichever real app bundle is running, and Engine's dev core uses 7457/7458.
The packaged app uses the protocol's 7447/7448. Logs: the core's output goes
to `~/Library/Logs/Rheocles/rheocles-core-php.log`; Laravel's to the app's
storage under `~/Library/Application Support/`.

`bin/sync-sidecar.sh` removes the old binary before copying: overwriting a
Mach-O in place on Apple Silicon leaves the kernel's signature cache stale
and the next launch is `Killed: 9` with nothing in any log.

Two front ends, one core: start the Swift app first and this one adopts its
daemon (`shared` in the strip); start this one alone and it launches its own
(`ours`). Quit only ever stops ours.

## Tests

```bash
php vendor/bin/pest      # PHP
npx vitest run           # the popover's state module
```

The lifecycle and every popover route run against a stub core
(`tests/stubs/core.php` on PHP's built-in server: streams, arming, takes,
markers, settings, token rotation, preview, reveal, combine — `STUB_COMBINE`
picks what the mux comes back as, `complete`, `failed` or `pending`, and
`Server::requests()` says exactly what went on the wire); the client and the SSE reader
run against the real `rheocles-core` binary on spare ports with their own
token file, settings file and output root — a real take with the manifest
on disk, settings, rotation, preview. Both need nothing running beforehand
and leave nothing behind. Tests that name an Engine bug (`(Engine: …)` in
the name) are meant to be red until the daemon is fixed.

## Packaging

```bash
bin/sync-sidecar.sh                    # the core, freshly built
php artisan native:build mac arm64     # signs with the Developer ID in the login keychain
```

electron-builder finds `Developer ID Application: Artisan Build, Inc` in the
keychain on its own; nothing in `.env` names it. Notarisation runs only
when `NATIVEPHP_APPLE_ID`, `NATIVEPHP_APPLE_ID_PASS` and
`NATIVEPHP_APPLE_TEAM_ID` are set, and `build/notarize.js` **fails the build
when it fails** (the scaffold printed "done notarizing" over a caught
error). The output is `nativephp/electron/dist/mac-arm64/Rheocles.app` and
a DMG beside it; `RHEOCLES_*` and the Apple credentials are stripped from
the bundled `.env`, so the bundle talks to the protocol's 7447/7448.

Then verify the entitlements **from the signature**, on the app and on the
nested core — never from configuration. Under the hardened runtime a
missing `device.camera` or `device.audio-input` does not fail loudly: the
app cannot prompt and never appears in Privacy & Security at all.

```bash
APP=nativephp/electron/dist/mac-arm64/Rheocles.app
codesign -d --entitlements :- "$APP" | grep -E "device\.(camera|audio-input)"
codesign -d --entitlements :- "$APP/Contents/extras/rheocles-core" | grep -E "device\.(camera|audio-input)"
codesign --verify --deep --strict --verbose=2 "$APP"
plutil -p "$APP/Contents/Info.plist" | grep -E "UsageDescription|LSUIElement"
```

The core inherits the bundle's TCC identity: the prompts macOS shows for
`rheocles-core` are this bundle's usage strings, in this bundle's name,
and the grants attach to this bundle id (`build.artisan.rheocles.php`) —
separate from the Swift app's, and persistent across rebuilds as long as
the signing identity stays the same. **Changing the signing identity
changes the TCC identity** and every grant vanishes.

## Lifting it into Pteroprompter

This directory is a whole NativePHP app on purpose, so ptero takes files,
not ideas. What moves and what it needs:

| take | it is | it needs |
|---|---|---|
| `app/Rheocles/` | the daemon: lifecycle, client, SSE reader, icon state, token, home | `config/rheocles.php`; Laravel's `Http` facade; NativePHP `ChildProcess` |
| `app/Console/Commands/Watch.php` | `rheo:watch`, the one long-lived process | started once from the native provider: `ChildProcess::artisan('rheo:watch', alias: 'rheo-watch', persistent: true)` |
| `resources/menubar/*.png` + `bin/make-icons.swift` | the tray icon, every state | `MenuBar::icon()` at runtime — or ptero's own tray, fed by `IconState` |
| `resources/views/menubar.blade.php`, `public/popover.css`, `public/js/state.js`, `public/js/popover.js`, `public/fonts/` | the popover; `state.js` is the pure part | a page that gets `window.RHEO` (base URL, events URL, token, published daemon state, preferences, home, token file) |
| `routes/web.php` (everything under `/api/`, `/daemon`, `/quit`) | clicks → the daemon, in the daemon's error shape | CSRF as usual; the `PreventRegularBrowserAccess` middleware is NativePHP's |
| `extras/rheocles-core` + `bin/sync-sidecar.sh` | the sidecar | `extraFiles` in `electron-builder.mjs`; `NATIVEPHP_EXTRAS_PATH` at runtime |
| `nativephp/electron/build/entitlements.mac.plist`, the `extendInfo` block in `electron-builder.mjs`, `build/notarize.js`, the error handler in `src/main/index.js` | what the scaffold gets wrong for an app that records | copy the keys and the comments; they mark paid-for traps |
| `tests/` | the stub core, the real-binary tests, the JS tests | `RHEOCLES_*` and `VIEW_COMPILED_PATH` in `phpunit.xml`; `vitest.config.js` |

Rules that travel with it: PHP is never between the daemon and the DOM
(the page holds `GET /events`; PHP handles clicks); the daemon is found
before it is launched and only ours is ever stopped; two front ends share
one core; the token is read from the daemon's file, again on every 401;
the icon speaks for the daemon; **the daemon opens the Finder** —
`POST /takes/{id}/reveal` and `POST /reveal`, never the shell from PHP or
Electron, so a browser front end gets the same button (a daemon too old
for the route answers `no such route`, which the page reads as "update
Rheocles", not as a missing file); the single file is the daemon's
`settings.combine` and `manifest.combined`, the page only shows them. The palette and type are `docs/BRAND.md`'s
— ptero's own chrome wraps the popover, it does not restyle it.
