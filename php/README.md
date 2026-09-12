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
| `resources/views/menubar.blade.php`, `public/popover.css`, `public/js/` | the popover |
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
php artisan native:run                             # the app, on the desktop
```

**`plugin:build` is not optional.** NativePHP 2.3.0 publishes an
`electron-plugin/dist` missing `server/pdfPageSize.js`; without rebuilding
the plugin `native:run` prints a success line and then dies on
`No electron app entry file found`.

In development the daemon runs on **7467/7468** (`.env`); `:7447` belongs to
whichever real app bundle is running, and Engine's dev core uses 7457/7458.
The packaged app uses the protocol's 7447/7448. Logs: the core's output goes
to `~/Library/Logs/Rheocles/rheocles-core-php.log`; Laravel's to the app's
storage under `~/Library/Application Support/`.

Two front ends, one core: start the Swift app first and this one adopts its
daemon (`shared` in the strip); start this one alone and it launches its own
(`ours`). Quit only ever stops ours.

## Tests

```bash
php vendor/bin/pest
```

The lifecycle runs against a stub core (`tests/stubs/core.php` on PHP's
built-in server); the client and the SSE reader run against the real
`rheocles-core` binary on spare ports with their own token file and output
root. Both need nothing running beforehand and leave nothing behind.

## Packaging

```bash
php artisan native:build mac arm64
```

Then verify the entitlements from the signature, on the app **and** the
nested binary — never from configuration:

```bash
codesign -d --entitlements :- nativephp/electron/dist/mac-arm64/Rheocles.app
codesign -d --entitlements :- nativephp/electron/dist/mac-arm64/Rheocles.app/Contents/extras/rheocles-core
```
