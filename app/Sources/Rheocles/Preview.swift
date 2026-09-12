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
        [
            (
                "idle",
                AnyView(MenuBarView(daemon: .staged(.running, discovery: discovery())))
            ),
            (
                "idle-shared-daemon",
                AnyView(
                    MenuBarView(
                        daemon: .staged(.running, discovery: discovery(freeBytes: nil), ours: false)
                    ))
            ),
            ("launching", AnyView(MenuBarView(daemon: .staged(.launching)))),
            (
                "daemon-down",
                AnyView(
                    MenuBarView(
                        daemon: .staged(
                            .down(
                                "rheocles-core exited with status 1"
                            ))))
            ),
        ]
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
        let rows: [(String, Color, Double, RheoclesMark.Streams, Set<Int>)] = [
            ("idle", Brand.aegean, 0.4, .solid, []),
            ("armed", Brand.ochre, 1, .outline, []),
            ("recording", Brand.oxide, 1, .solid, []),
            ("late join", Brand.oxide, 1, .solid, [2]),
        ]
        return AnyView(
            Grid(alignment: .center, horizontalSpacing: 26, verticalSpacing: 18) {
                GridRow {
                    Text("")
                    ForEach(sizes, id: \.self) { size in
                        Text("\(Int(size))")
                            .font(Type.mono(8))
                            .foregroundStyle(Brand.script)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0)
                            .font(Type.kicker())
                            .foregroundStyle(Brand.script)
                            .gridColumnAlignment(.leading)
                        ForEach(sizes, id: \.self) { size in
                            RheoclesMark(
                                streams: row.3, lateJoined: row.4, weight: size <= 20 ? 3.2 : 3
                            )
                            .foregroundStyle(row.1)
                            .opacity(row.2)
                            .frame(width: size, height: size)
                        }
                    }
                }
            }
            .padding(22)
            .background(Brand.panel)
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
