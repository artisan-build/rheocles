# Capture

Owned by Engine. Measurements of capture behaviour (latency, drift,
timecode, HEVC tiers). Spikes S1–S3 under `app/Scripts/spikes/` hold the
raw evidence for the mechanisms; this file collects the numbers the build
relies on.

## Permissions (spec §4, verified)

macOS 26.6, hardened runtime, Developer ID signed dev bundle
(`app/Scripts/dev-core.sh`):

| capability | Info.plist key | entitlement | prompt |
|---|---|---|---|
| camera | `NSCameraUsageDescription` | `com.apple.security.device.camera` | on the first arm |
| microphone | `NSMicrophoneUsageDescription` | `com.apple.security.device.audio-input` | on the first arm |
| system audio | `NSAudioCaptureUsageDescription` | none beyond audio-input | "System Audio Recording", on the first tap |
| screen / windows | none | none | ScreenCaptureKit's own, on the first `SCShareableContent` query |

Without the usage string the request is refused instantly and silently and
the app never appears in System Settings; a bare executable's request is
attributed to whatever launched it (S1). `CGPreflightScreenCaptureAccess`
is fixed for the life of a process — a grant shows up on the next launch.

## Disk pre-flight estimates (rough, until the tiers are measured)

Bits per pixel per frame: HEVC 0.15 (1080p30 ≈ 9 Mb/s, 4K60 ≈ 75 Mb/s),
ProRes 422 2.4 (1080p30 ≈ 147 Mb/s). Audio: sample rate × 24 × channels.
Replaced by the measured HEVC tiers in task 4 step 9.

## HEVC tiers

To be measured (task 4 step 9): the HEVC bitrate at which 1080p and 4K are
visually indistinguishable from ProRes 422 on a calibrated display, with
the method and the numbers.
