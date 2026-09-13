import AppKit
import RheoclesCore
import SwiftUI

/// Renders the popover to PNGs and exits.
///
///     Rheocles.app/Contents/MacOS/Rheocles --render-preview <directory>
///
/// A design feedback loop that does not need a human. Every state the popover
/// can be in gets written out, including the ones that are awkward to reach
/// by hand — a daemon that will not start, a launch in progress — so the
/// layout is judged in the states it will actually be seen in rather than
/// only the one it happens to be in right now.
///
/// One known limitation, inherited with the pattern: `ImageRenderer` cannot
/// rasterise AppKit-backed controls and draws them as a filled accent
/// rectangle with a "no entry" glyph. Nothing here uses one — buttons are
/// `PillButton`, drawn from shapes — and anything added later that does will
/// show up that way in these PNGs before it shows up on a screen.
@MainActor
enum Preview {
    /// True while rendering, for the one view that has to lay out
    /// differently offscreen (see StreamList).
    static let isRendering = CommandLine.arguments.contains("--render-preview")

    static func renderIfRequested() -> Bool {
        let arguments = CommandLine.arguments

        guard let flag = arguments.firstIndex(of: "--render-preview"),
            flag + 1 < arguments.count
        else { return false }

        let directory = URL(fileURLWithPath: arguments[flag + 1])
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        var written: [String] = []
        for (name, view) in states() {
            let url = directory.appendingPathComponent("\(name).png")
            if write(view, to: url) { written.append(url.path) }
        }

        let marks = directory.appendingPathComponent("mark.png")
        if write(markSheet(), to: marks) { written.append(marks.path) }

        // The menu bar icon in every state, on both grounds it has to survive.
        // An icon that renders empty is invisible rather than wrong, which is
        // the hardest kind of broken to notice.
        let icons: [(String, MenuBarIcon.State)] = [
            ("menubar-idle", .idle),
            ("menubar-armed", .armed),
            ("menubar-recording", .recording),
            ("menubar-recording-late-join", .recording(lateJoined: [2])),
        ]
        for (name, state) in icons {
            let url = directory.appendingPathComponent("\(name).png")
            if write(iconSheet(MenuBarIcon.image(for: state)), to: url) {
                written.append(url.path)
            }
        }

        for path in written { print(path) }
        return true
    }

    private static func states() -> [(String, AnyView)] {
        let granted = Permissions(camera: .authorized, microphone: .authorized, screen: .authorized)
        return [
            (
                "idle",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(), streams: streams(),
                            permissions: granted)))
            ),
            (
                "armed",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(),
                            streams: streams(armed: [
                                "display:56A96CFC", "camera:4kx", "microphone:scarlett",
                                "systemAudio:system",
                            ]),
                            permissions: granted)))
            ),
            (
                "armed-show-windows",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(),
                            streams: streams(armed: ["camera:4kx", "window:9565"]),
                            permissions: granted, showWindows: true)))
            ),
            (
                "permissions",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(freeBytes: nil), ours: false,
                            streams: streams().filter {
                                $0.kind != .display && $0.kind != .window
                            },
                            permissions: Permissions(
                                camera: .denied, microphone: .authorized, screen: .notDetermined))))
            ),
            (
                // What the daemon says today, before Engine step 3 lands:
                // the switch snaps back and the refusal is shown verbatim.
                "arm-refused",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(), streams: streams(),
                            permissions: granted,
                            armError: "POST /streams/camera:4kx/arm → 404 not_found: no such route")
                    ))
            ),
            (
                "armed-named",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(),
                            streams: streams(armed: ["camera:4kx", "microphone:scarlett"]),
                            permissions: granted, takeName: "ep12")))
            ),
            (
                "recording",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(),
                            streams: streams(armed: [
                                "display:56A96CFC", "camera:4kx", "microphone:scarlett",
                                "systemAudio:system",
                            ]),
                            permissions: granted, take: manifest(state: "recording", elapsed: 257)))
                )
            ),
            (
                "recording-late-join",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(),
                            streams: streams(armed: [
                                "display:56A96CFC", "camera:4kx", "microphone:scarlett",
                                "systemAudio:system",
                            ]),
                            permissions: granted,
                            take: manifest(state: "recording", elapsed: 257, lateJoin: 2))))
            ),
            (
                "combine",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(),
                            streams: streams(armed: ["camera:4kx", "microphone:scarlett"]),
                            permissions: granted, combine: true)))
            ),
            (
                "take-complete-combined-pending",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(),
                            streams: streams(armed: ["camera:4kx", "microphone:scarlett"]),
                            permissions: granted, take: manifest(state: "complete", elapsed: 743),
                            combine: true,
                            combined: Combined(path: "combined.mov", state: .pending))))
            ),
            (
                "take-complete-combined",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(),
                            streams: streams(armed: ["camera:4kx", "microphone:scarlett"]),
                            permissions: granted, take: manifest(state: "complete", elapsed: 743),
                            combine: true,
                            combined: Combined(path: "combined.mov", state: .complete),
                            recent: recentTakes(), showRecent: true)))
            ),
            (
                "take-complete-combined-failed",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(),
                            streams: streams(armed: ["camera:4kx", "microphone:scarlett"]),
                            permissions: granted, take: manifest(state: "complete", elapsed: 743),
                            combine: true,
                            combined: Combined(
                                path: "combined.mov", state: .failed,
                                reason: "export cancelled: disk full"))))
            ),
            (
                "take-complete",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(),
                            streams: streams(armed: ["camera:4kx", "microphone:scarlett"]),
                            permissions: granted, take: manifest(state: "complete", elapsed: 743))))
            ),
            (
                "take-incomplete",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(),
                            streams: streams(armed: ["camera:4kx", "microphone:scarlett"]),
                            permissions: granted,
                            take: manifest(
                                state: "incomplete", elapsed: 88, reason: "disk full"))))
            ),
            (
                "levels",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(),
                            streams: streams(armed: [
                                "microphone:scarlett", "microphone:mbp", "systemAudio:system",
                            ]),
                            permissions: granted,
                            levels: ["microphone:scarlett": -18, "systemAudio:system": -2])))
            ),
            (
                "preview",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(),
                            streams: streams(armed: ["camera:4kx"]), permissions: granted,
                            previewing: "camera:4kx", previewFrame: frame())))
            ),
            (
                "preview-refused",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(), streams: streams(),
                            permissions: granted, previewing: "display:56A96CFC",
                            previewError:
                                "GET /preview/display:56A96CFC → 404 not_found: no such route")))
            ),
            (
                "recording-markers",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(),
                            streams: streams(armed: ["camera:4kx", "microphone:scarlett"]),
                            permissions: granted,
                            take: manifest(state: "recording", elapsed: 257, markers: 2),
                            levels: ["microphone:scarlett": -24])))
            ),
            (
                "settings",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(), streams: streams(),
                            permissions: granted, showSettings: true)))
            ),
            (
                "settings-rotate-armed",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(), streams: streams(),
                            permissions: granted, showSettings: true, rotateArmed: true)))
            ),
            (
                "recording-stalled",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(),
                            streams: streams(armed: [
                                "display:56A96CFC", "camera:4kx", "microphone:scarlett",
                                "systemAudio:system",
                            ]),
                            permissions: granted,
                            take: manifest(state: "recording", elapsed: 257),
                            levels: ["microphone:scarlett": -20, "systemAudio:system": -31],
                            stalled: ["camera:4kx"],
                            streamStatus: [
                                "display:56A96CFC": StreamStatus(
                                    id: "display:56A96CFC", levelDb: nil, framesWritten: 15420,
                                    drift: 0.003),
                                "camera:4kx": StreamStatus(
                                    id: "camera:4kx", levelDb: nil, framesWritten: 4102, drift: nil),
                                "microphone:scarlett": StreamStatus(
                                    id: "microphone:scarlett", levelDb: -20,
                                    framesWritten: 12_336_000, drift: -0.001),
                                "systemAudio:system": StreamStatus(
                                    id: "systemAudio:system", levelDb: -31,
                                    framesWritten: 12_336_000, drift: 0),
                            ])))
            ),
            (
                "settings-token-shown",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .running, discovery: discovery(), streams: streams(),
                            permissions: granted, showSettings: true, tokenShown: true)))
            ),
            ("launching", AnyView(MenuBarView(daemon: .staged(.launching)))),
            (
                "daemon-down",
                AnyView(
                    MenuBarView(
                        daemon: .staged(.down("rheocles-core exited with status 1"))))
            ),
        ]
    }

    /// A manifest in the daemon's shape (PROTOCOL § Takes), with the cue
    /// `elapsed` seconds ago so the counter shows a real duration. `lateJoin`
    /// names the index of one stream that joined four minutes in.
    private static func manifest(
        state: String, elapsed: Double, lateJoin: Int? = nil, reason: String? = nil,
        markers: Int = 0
    ) -> Manifest {
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let now = Date()
        let cue = now.addingTimeInterval(-elapsed)
        let over = state == "complete" || state == "incomplete"
        let stopped = over ? ", \"stopped\": \"\(iso.format(now))\"" : ""
        let files = [
            (
                "display:56A96CFC", "display", "BenQ PD3220U", "benq-pd3220u.mov", "hevc",
                "\"video\": { \"width\": 3840, \"height\": 2160, \"maxFrameRate\": 60 }"
            ),
            (
                "camera:4kx", "camera", "Elgato 4K X", "elgato-4k-x.mov", "hevc",
                "\"video\": { \"width\": 3840, \"height\": 2160, \"maxFrameRate\": 30 }"
            ),
            (
                "microphone:scarlett", "microphone", "Scarlett 2i2 USB", "scarlett-2i2-usb.wav",
                "pcm_s24le", "\"audio\": { \"sampleRate\": 48000, \"channels\": 2 }"
            ),
            (
                "systemAudio:system", "systemAudio", "System audio", "system-audio.wav",
                "pcm_s24le", "\"audio\": { \"sampleRate\": 48000, \"channels\": 2 }"
            ),
        ]
        let streams = files.enumerated().map { index, f in
            let began = index == lateJoin ? cue.addingTimeInterval(240) : cue
            return """
                { "id": "\(f.0)", "kind": "\(f.1)", "name": "\(f.2)", "model": "…",
                  "path": "\(f.3)", "codec": "\(f.4)", "format": { \(f.5) },
                  "started": "\(iso.format(began))"\(stopped),
                  "framesWritten": 7710, "events": [ { "t": \(index == lateJoin ? 240 : 0), "type": "join" } ] }
                """
        }
        let json = """
            {
              "id": "20260911T140217-7f3a", "name": "ep12", "state": "\(state)",
              \(reason.map { "\"reason\": \"\($0)\"," } ?? "")
              "created": "\(iso.format(cue.addingTimeInterval(-8)))",
              "started": "\(iso.format(cue))"\(stopped),
              "outputRoot": "\(FileManager.default.homeDirectoryForCurrentUser.path)/Movies/Rheocles",
              "destination": "takes/2026-09-11/140217-ep12",
              "version": "0.1.0",
              "machine": { "hostname": "lens-macbook-pro.local", "machineId": "CD3B7EE5" },
              "streams": [\(streams.joined(separator: ","))],
              "markers": [\((0..<markers).map { "{ \"t\": \(38.7 + Double($0) * 90), \"label\": \"marker \($0 + 1)\" }" }.joined(separator: ","))],
              "settings": { "codec": "hevc" }
            }
            """
        return try! Manifest.wireDecoder.decode(Manifest.self, from: Data(json.utf8))
    }

    /// `GET /takes` as the daemon lists it, newest first.
    private static func recentTakes() -> [TakeEngine.Summary] {
        let json = """
            [
              { "id": "20260911T140217-7f3a", "name": "ep12", "state": "complete",
                "created": "2026-09-11T14:02:09.412Z", "destination": "takes/2026-09-11/140217-ep12", "streams": 2 },
              { "id": "20260911T113000-a1b2", "name": "cold open", "state": "complete",
                "created": "2026-09-11T11:30:00.000Z", "destination": "takes/2026-09-11/113000-cold-open", "streams": 4 },
              { "id": "20260910T170500-c3d4", "name": null, "state": "incomplete",
                "created": "2026-09-10T17:05:00.000Z", "destination": "takes/2026-09-10/170500", "streams": 1 }
            ]
            """
        return try! Manifest.wireDecoder.decode([TakeEngine.Summary].self, from: Data(json.utf8))
    }

    /// A stand-in preview frame: no daemon is rendering, so a 16:9 field of
    /// the fresco's colours says "an image goes here" without pretending
    /// to be one.
    private static func frame() -> NSImage {
        let size = NSSize(width: 640, height: 360)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(
            colors: [NSColor(Brand.aegeanDeep), NSColor(Brand.aegeanSoft), NSColor(Brand.ochre)])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 20)
        let text = "preview · 3840×2160 · 30" as NSString
        text.draw(
            at: NSPoint(x: 18, y: 16),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .medium),
                .foregroundColor: NSColor(Brand.ground),
            ])
        image.unlockFocus()
        return image
    }

    /// This Mac's streams as `rheocles-core --list-streams` reported them on
    /// 11 Sep 2026, in the daemon's fixed order, so the preview is judged on
    /// real names and real numbers.
    private static func streams(armed: Set<String> = []) -> [StreamInfo] {
        func video(_ w: Int, _ h: Int, _ fps: Double) -> StreamInfo.Capabilities {
            .init(video: .init(width: w, height: h, maxFrameRate: fps))
        }
        func audio(_ ch: Int) -> StreamInfo.Capabilities {
            .init(audio: .init(sampleRate: 48000, channels: ch))
        }
        let all: [StreamInfo] = [
            .init(
                id: "display:56A96CFC", kind: .display, name: "BenQ PD3220U",
                model: "vendor 2513 model 32813", capabilities: video(3840, 2160, 60)),
            .init(
                id: "window:9565", kind: .window, name: "Solo — Solo", model: "com.soloterm.solo",
                capabilities: video(1852, 1684, 60)),
            .init(
                id: "window:11597", kind: .window,
                name: "Google Chrome — Timecode and sync — Rheocles docs",
                model: "com.google.Chrome", capabilities: video(1200, 900, 60)),
            .init(
                id: "camera:4kx", kind: .camera, name: "Elgato 4K X",
                model: "UVC Camera VendorID_4057 ProductID_156",
                capabilities: video(3840, 2160, 30.00003)),
            .init(
                id: "camera:hd60x", kind: .camera, name: "Elgato HD60 X",
                model: "UVC Camera VendorID_4057 ProductID_138",
                capabilities: video(3840, 2160, 30.00003)),
            .init(
                id: "camera:obs", kind: .camera, name: "OBS Virtual Camera",
                model: "OBS Camera Extension", capabilities: video(1920, 1080, 60)),
            .init(
                id: "camera:facetime", kind: .camera, name: "FaceTime HD Camera",
                model: "FaceTime HD Camera", capabilities: video(1280, 720, 30)),
            .init(
                id: "microphone:scarlett", kind: .microphone, name: "Scarlett 2i2 USB",
                model: "Scarlett 2i2 USB:1235:8210", capabilities: audio(2)),
            .init(
                id: "microphone:4kx", kind: .microphone, name: "Elgato 4K X",
                model: "Elgato 4K X:0FD9:009C", capabilities: audio(2)),
            .init(
                id: "microphone:mbp", kind: .microphone, name: "MacBook Pro Microphone",
                model: "Digital Mic", capabilities: audio(1)),
            .init(
                id: "systemAudio:system", kind: .systemAudio, name: "System audio",
                model: "Core Audio tap", capabilities: audio(2)),
        ]
        return all.map { stream in
            var s = stream
            s.armed = armed.contains(stream.id)
            return s
        }
    }

    /// A `GET /` answer, decoded from the protocol's own example so the
    /// preview shows exactly the shape a real daemon sends.
    private static func discovery(freeBytes: Int64? = 44_878_079_167) -> Discovery {
        let free = freeBytes.map { "\"freeBytes\": \($0)," } ?? ""
        let json = """
            {
              "name": "Rheocles",
              "version": "0.1.0",
              "hostname": "lens-macbook-pro.local",
              "machineId": "CD3B7EE5-5E6C-5155-854A-72E4728555F7",
              "outputRoot": "\(FileManager.default.homeDirectoryForCurrentUser.path)/Movies/Rheocles",
              \(free)
              "auth": "bearer",
              "ports": { "http": 7447, "ws": 7448 }
            }
            """
        return try! JSONDecoder().decode(Discovery.self, from: Data(json.utf8))
    }

    /// The mark at the sizes it is used, in every state, on the panel. One
    /// row per state, one column per size, so a state is compared across
    /// sizes and a size across states without moving the eye far.
    private static func markSheet() -> AnyView {
        let sizes: [CGFloat] = [18, 20, 34, 64]
        let rows: [(String, Color, Double, RheoclesMark.Streams, Set<Int>, Bool)] = [
            ("idle", Brand.aegean, 0.4, .solid, [], false),
            ("armed · icon", Brand.aegean, 1, .solid, [], false),
            ("armed · popover", Brand.ochre, 1, .outline, [], false),
            ("recording", Brand.oxide, 1, .solid, [], true),
            ("late join", Brand.oxide, 1, .solid, [2], true),
        ]
        return AnyView(
            Grid(alignment: .center, horizontalSpacing: 26, verticalSpacing: 18) {
                GridRow {
                    Text("")
                    ForEach(sizes, id: \.self) { size in
                        Text("\(Int(size))")
                            .font(Type.mono(8))
                            .foregroundStyle(Brand.inkFaint)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0)
                            .font(Type.kicker())
                            .foregroundStyle(Brand.aegean)
                            .gridColumnAlignment(.leading)
                        ForEach(sizes, id: \.self) { size in
                            RheoclesMark(
                                streams: row.3, lateJoined: row.4, cueDot: row.5,
                                weight: size <= 20 ? 3.2 : 3
                            )
                            .foregroundStyle(row.1)
                            .opacity(row.2)
                            .frame(width: size, height: size)
                        }
                    }
                }
            }
            .padding(22)
            .background(Brand.ground)
        )
    }

    private static func iconSheet(_ icon: NSImage) -> AnyView {
        AnyView(
            HStack(spacing: 20) {
                ForEach([Color.black, Color.white], id: \.self) { ground in
                    Image(nsImage: icon)
                        .renderingMode(.template)
                        .foregroundStyle(ground == .black ? Color.white : Color.black)
                        .frame(width: 34, height: 34)
                        .padding(10)
                        .background(ground)
                }
            }
            .padding(16)
            .background(Color.gray)
        )
    }

    @discardableResult
    private static func write(_ view: some View, to url: URL) -> Bool {
        let renderer = ImageRenderer(content: view)
        // Two, so the rendering matches what a Retina display shows and the
        // hairlines are judged at the density they will be seen at.
        renderer.scale = 2

        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("could not render \(url.lastPathComponent)\n".utf8))
            return false
        }

        do {
            try png.write(to: url)
            return true
        } catch {
            FileHandle.standardError.write(Data("could not write \(url.path): \(error)\n".utf8))
            return false
        }
    }
}
