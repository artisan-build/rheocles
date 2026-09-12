// swift-tools-version: 6.0
import PackageDescription

// Rheocles — records any number of input streams simultaneously, each to its
// own file, on one cue, stamped with time-of-day timecode.
//
// One engine, two front ends:
//
//   RheoclesCore   streams, arming, takes, writers, clock, manifest, auth and
//                  the two API transports. Everything real happens here.
//   rheocles-core  the headless daemon: a thin main over RheoclesCore that
//                  binds 7447 (HTTP + SSE) and 7448 (WebSocket) on loopback.
//   Rheocles       the menu bar app, a client of the daemon over the API.
//                  Added by Rheo App — see the marked spot below.
//
// macOS 15 is the floor (spec §4): mature ScreenCaptureKit and Core Audio
// process taps. Spikes S1–S3 under Scripts/spikes/ decided the capture
// mechanisms; nothing here depends on anything they did not confirm.
let package = Package(
    name: "Rheocles",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "RheoclesCore", targets: ["RheoclesCore"]),
        .executable(name: "rheocles-core", targets: ["rheocles-core"]),
        .executable(name: "Rheocles", targets: ["Rheocles"]),
    ],
    targets: [
        .target(name: "RheoclesCore"),
        .executableTarget(name: "rheocles-core", dependencies: ["RheoclesCore"]),
        .executableTarget(name: "Rheocles", dependencies: ["RheoclesCore"], exclude: ["Fonts"]),
        .testTarget(name: "RheoclesCoreTests", dependencies: ["RheoclesCore"]),
    ]
)
