#!/bin/sh
# Runs the debug daemon inside a signed development bundle, so macOS has a
# stable TCC identity for it while Rheocles.app does not exist yet.
#
#   Scripts/dev-core.sh start [rheocles-core args]   build, wrap, sign, launch
#   Scripts/dev-core.sh stop
#   Scripts/dev-core.sh log
#
# Why a bundle: a bare executable's device requests are attributed to the
# process that launched it (S1: a Terminal, or a host with no camera usage
# string at all), and an ad-hoc signature is a different app to TCC on every
# build. Bundle id build.artisan.rheocles.core-dev, signed with the Developer
# ID from the login keychain, keeps one set of grants — Camera, Microphone,
# Screen & System Audio Recording — across rebuilds. Those grants belong to
# this bundle only; the real app gets its own on first launch.
#
# Not for distribution and not what bundle.sh builds: no Rheocles.app, no
# notarisation, and the daemon is the main executable rather than nested.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/RheoclesCoreDev.app"
LOG="$DIST/rheocles-core-dev.log"
SIGN="${SIGN_ID:-Developer ID Application: Artisan Build, Inc (83AD4SGJLW)}"

case "${1:-}" in
start)
  shift
  swift build --package-path "$ROOT" >/dev/null
  BIN="$(swift build --package-path "$ROOT" --show-bin-path)"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS"
  cp "$BIN/rheocles-core" "$APP/Contents/MacOS/rheocles-core"
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>build.artisan.rheocles.core-dev</string>
    <key>CFBundleName</key><string>RheoclesCoreDev</string>
    <key>CFBundleExecutable</key><string>rheocles-core</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSBackgroundOnly</key><true/>
    <key>NSCameraUsageDescription</key>
    <string>Rheocles records cameras you arm, each to its own file.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Rheocles records microphones you arm, each to its own file.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Rheocles records system audio when you arm it.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Rheocles records displays and windows you arm, each to its own file.</string>
</dict>
</plist>
PLIST
  codesign --force --options runtime --timestamp=none \
    --entitlements "$ROOT/Scripts/Rheocles.entitlements" --sign "$SIGN" "$APP"
  codesign --verify --strict "$APP"
  rm -f "$LOG"
  # Isolate the dev daemon's settings and token in dist/, so --output-root and
  # rotations never touch the user's real ~/Library/Application Support files.
  open -n --stdout "$LOG" --stderr "$LOG" -a "$APP" --args \
    --settings-file "$DIST/dev-settings.json" --token-file "$DIST/dev-token" "$@"
  sleep 1
  cat "$LOG"
  ;;
stop)
  pkill -f "$APP/Contents/MacOS/rheocles-core" && echo "stopped" || echo "not running"
  ;;
log)
  cat "$LOG"
  ;;
*)
  echo "usage: $0 start [args] | stop | log" >&2
  exit 1
  ;;
esac
