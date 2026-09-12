#!/bin/sh
# Minimal signed .app, same arrangement as S2: stable bundle id + Developer
# ID so the microphone grant survives rebuilds. Hardened runtime with the
# audio-input entitlement, or the mic is refused before TCC is asked.
set -eu
cd "$(dirname "$0")"
APP=S3.app
SIGN="${SIGN_ID:-Developer ID Application: Artisan Build, Inc (83AD4SGJLW)}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/s3" main.swift \
  -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework CoreText -framework CoreGraphics
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --timestamp=none --entitlements S3.entitlements --sign "$SIGN" "$APP"
codesign --verify --strict "$APP"
echo "built $APP, signed as: $(codesign -dvv "$APP" 2>&1 | grep '^Authority' | head -1)"
