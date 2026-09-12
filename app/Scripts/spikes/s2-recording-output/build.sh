#!/bin/sh
# Builds the S2 spike as a minimal signed .app so that TCC has a stable
# identity for it: the Screen Recording grant follows the signing identity
# and the bundle id, so it survives rebuilds. Signed with the Developer ID
# from the login keychain (SIGN_ID overrides). LSBackgroundOnly: no Dock
# icon, no window; launch with `open`, log via --stdout/--stderr.
set -eu
cd "$(dirname "$0")"
APP=S2.app
SIGN="${SIGN_ID:-Developer ID Application: Artisan Build, Inc (83AD4SGJLW)}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/s2" main.swift \
  -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia -framework AppKit
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --timestamp=none --sign "$SIGN" "$APP"
codesign --verify --strict "$APP"
echo "built $APP, signed as: $(codesign -dvv "$APP" 2>&1 | grep "^Authority" | head -1)"
