#!/usr/bin/env bash
# Assemble Rheocles.app from the SwiftPM executable.
#
# SwiftPM builds a bare Mach-O; macOS needs a bundle. That is not ceremony —
# the Info.plist is what carries LSUIElement (no Dock icon, no app switcher)
# and, more importantly, what gives the app its own TCC identity. Run as a bare
# executable, microphone permission attaches to whatever terminal launched it,
# which is why the original spike asked you to grant Terminal mic access by
# hand. A bundle gets its own entry in System Settings.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
DIST="$ROOT/../dist"
APP="$DIST/Rheocles.app"

# The version was hardcoded here until a Homebrew cask made that untenable: a
# cask declaring 0.1.1 around an app whose Info.plist still says 0.1.0 breaks
# `brew upgrade` detection, because Homebrew compares the two.
#
# VERSION wins if set — that is how CI passes the tag. Otherwise take the
# nearest tag, so a local build is stamped with something true rather than
# whatever was last typed into this file. --abbrev=0 keeps it to the tag
# itself; CFBundleShortVersionString must be dot-separated digits, and
# "v0.1.0-3-g56ff482" is not.
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)}"
VERSION="${VERSION#v}"

# CFBundleVersion is the build number and must never go backwards. Commit
# count is monotonic on a branch that only moves forward, and needs nothing
# stored anywhere.
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

# One invocation, not two. --show-bin-path is cheap but it still plans the
# build, and there is no reason to do that twice for a path we can ask for once.
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"
swift build -c "$CONFIG" --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Rheocles" "$APP/Contents/MacOS/Rheocles"
cp "$BIN/rheocles-core" "$APP/Contents/Resources/rheocles-core"
# The family's faces, OFL, registered by the app at launch (Brand.swift).
cp -R "$ROOT/Sources/Rheocles/Fonts" "$APP/Contents/Resources/Fonts"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>build.artisan.rheocles</string>
    <key>CFBundleName</key><string>Rheocles</string>
    <key>CFBundleDisplayName</key><string>Rheocles</string>
    <key>CFBundleExecutable</key><string>Rheocles</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <!-- Spec §4: macOS 15 for SCRecordingOutput and mature Core Audio taps. -->
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>
    <!--
      The daemon, not the app, opens the devices — but it runs as a child of
      this bundle, so this is the plist macOS reads when it decides whether
      the process may ask. One usage string per capability the daemon records
      (spec §4, "verify each, assume none"); each needs its entitlement too,
      in Rheocles.entitlements, or the app never appears under Privacy at all.
      Screen and window capture have no key: ScreenCaptureKit raises its own
      prompt. NSAudioCaptureUsageDescription is the system-audio key — verified
      against the key list in tccd on macOS 26.6.
    -->
    <key>NSCameraUsageDescription</key>
    <string>Rheocles records each camera you arm to its own file.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Rheocles records each microphone you arm to its own file.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Rheocles records system audio to its own file when you arm it.</string>
</dict>
</plist>
PLIST

# Ad-hoc unless SIGN_ID names a real identity. Ad-hoc signatures change on every
# build, so macOS may re-ask for the microphone after a rebuild; a Developer ID
# keeps one permission across rebuilds. Note that switching between the two
# makes this a *different app* to TCC — an existing grant does not carry over.
#
# The entitlements are not optional. The hardened runtime gates the microphone
# on com.apple.security.device.audio-input before TCC is consulted, so signing
# with --options runtime and no entitlements produces an app that cannot record
# and cannot ask to.
#
# Sign inside out, and not with --deep. rheocles-core is an executable living in
# Contents/Resources, which --deep treats as a resource rather than as nested
# code — so it kept the ad-hoc signature SwiftPM's linker gave it, and the
# notary service rejected the whole archive for it: no Developer ID, no secure
# timestamp, no hardened runtime. `codesign --verify --deep --strict` reports
# such a bundle as valid, so local verification will not catch this. Only
# notarisation will.
SIGN="${SIGN_ID:--}"

# Ad-hoc signatures cannot carry a secure timestamp; real ones must.
TS=(--timestamp)
if [ "$SIGN" = "-" ]; then
  TS=(--timestamp=none)
fi

for TARGET in "$APP/Contents/Resources/rheocles-core" "$APP"; do
  codesign --force --options runtime "${TS[@]}" \
    --entitlements "$ROOT/Scripts/Rheocles.entitlements" \
    --sign "$SIGN" "$TARGET"
done

echo "built $APP ($VERSION build $BUILD)"
