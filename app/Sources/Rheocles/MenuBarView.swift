import RheoclesCore
import SwiftUI

/// The popover behind the menu bar icon.
///
/// Task 1 shape: who the daemon is and whether it is answering. The streams,
/// the Record button and the settings arrive in the tasks that follow; the
/// frame they land in is this one — header, a centre panel with exactly one
/// state showing, controls beneath — so that the layout is judged now in the
/// grid it will keep.
///
/// Dark, on the family's shared grounds, with the Aegean signature where
/// Sonocles has terracotta. The 3 pt rule along the top is the site header's
/// `border-top`, so the popover and rheocles.com open the same way.
struct MenuBarView: View {
    let daemon: DaemonModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Brand.aegean).frame(height: 3)
            header
            rule
            centre
            rule
            controls
        }
        .frame(width: 344)
        .background(Brand.panel)
    }

    private var rule: some View {
        Rectangle().fill(Brand.field).frame(height: 1)
    }

    // MARK: - header

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            RheoclesMark(streams: .solid, weight: 3.4)
                .foregroundStyle(markColour)
                .frame(width: 20, height: 20)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Rheocles")
                    .font(Type.wordmark(15))
                    .foregroundStyle(Brand.bone)
                Text("REE-oh-kleez")
                    .font(Type.mono(9))
                    .foregroundStyle(Brand.script)
            }

            Spacer()

            StatePill(label: stateLabel, colour: stateColour)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var markColour: Color {
        switch daemon.status {
        case .running: Brand.aegean
        case .launching: Brand.aegean.opacity(0.5)
        case .down: Brand.script
        }
    }

    private var stateLabel: String {
        switch daemon.status {
        case .running: "Idle"
        case .launching: "Launching"
        case .down: "Down"
        }
    }

    private var stateColour: Color {
        switch daemon.status {
        case .running: Brand.script
        case .launching: Brand.aegean
        case .down: Brand.oxide
        }
    }

    // MARK: - centre

    @ViewBuilder private var centre: some View {
        Group {
            switch daemon.status {
            case .running: running
            case .launching: launching
            case .down(let why): down(why)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Brand.slip)
    }

    /// `GET /`, field by field. Kickers on the left, values in mono on the
    /// right: numbers should look like numbers.
    private var running: some View {
        let d = daemon.discovery
        return VStack(alignment: .leading, spacing: 6) {
            field("daemon") {
                HStack(spacing: 6) {
                    Text("running")
                        .foregroundStyle(Brand.verdigris)
                    Text("·").foregroundStyle(Brand.script)
                    Text(d?.version ?? "··")
                    Text("·").foregroundStyle(Brand.script)
                    Text(daemon.startedByUs ? "ours" : "shared")
                        .foregroundStyle(Brand.body)
                }
            }
            field("host") { Text(d?.hostname ?? "··") }
            field("machine") { Text(d?.machineId ?? "··").truncationMode(.middle) }
            field("output") { Text(d.map { Self.abbreviate($0.outputRoot) } ?? "··") }
            field("free") {
                Text(d?.freeBytes.map(Self.bytes) ?? "··")
                    .foregroundStyle(d?.freeBytes == nil ? Brand.script : Brand.bone)
            }
            field("api") {
                HStack(spacing: 6) {
                    Text("http :\(String(d?.ports.http ?? 0))")
                    Text("·").foregroundStyle(Brand.script)
                    Text("ws :\(String(d?.ports.ws ?? 0))")
                    Text("·").foregroundStyle(Brand.script)
                    Text(d?.auth ?? "··")
                }
            }
        }
        .frame(height: 118, alignment: .top)
    }

    private var launching: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                kicker("daemon")
                Text("launching")
                    .font(Type.mono(11))
                    .foregroundStyle(Brand.aegean)
            }
            WorkingPulse(colour: Brand.aegean)
            Text(
                "Nothing answered on :\(String(Rheocles.defaultHTTPPort)), so the bundled rheocles-core is being started."
            )
            .font(Type.body(10.5))
            .foregroundStyle(Brand.script)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(height: 118, alignment: .center)
    }

    private func down(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                kicker("daemon")
                Text("down")
                    .font(Type.mono(11))
                    .foregroundStyle(Brand.oxide)
            }
            Text(why)
                .font(Type.body(10.5))
                .foregroundStyle(Brand.body)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
            Spacer(minLength: 0)
            HStack {
                PillButton("Relaunch", colour: Brand.aegean, filled: true) { daemon.relaunch() }
                Spacer()
                Text(Self.abbreviate(Log.daemonLog.path))
                    .font(Type.mono(9))
                    .foregroundStyle(Brand.script)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(height: 118, alignment: .top)
    }

    private func field(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            kicker(label)
            value()
                .font(Type.mono(11))
                .foregroundStyle(Brand.bone)
                .lineLimit(1)
        }
    }

    private func kicker(_ label: String) -> some View {
        Text(label.uppercased())
            .font(Type.kicker())
            .kerning(1.1)
            .foregroundStyle(Brand.script)
            .frame(width: 58, alignment: .leading)
    }

    // MARK: - controls

    private var controls: some View {
        HStack {
            Text("token · \(Self.abbreviate(daemon.tokenFile.path))")
                .font(Type.mono(9))
                .foregroundStyle(Brand.script)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            PillButton("Quit", colour: Brand.body, filled: false) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - formatting

    static func bytes(_ count: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useTB, .useMB]
        return f.string(fromByteCount: count)
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// The site's pill button, drawn from shapes.
///
/// A system `Button` in a bordered style is AppKit-backed and neither matches
/// the panel nor survives `ImageRenderer` — so the design could not be
/// reviewed without a human at a screen. A capsule and a label solve both.
struct PillButton: View {
    let label: String
    let colour: Color
    let filled: Bool
    let action: () -> Void

    init(_ label: String, colour: Color, filled: Bool, action: @escaping () -> Void) {
        self.label = label
        self.colour = colour
        self.filled = filled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Type.body(11, .semibold))
                .foregroundStyle(filled ? Brand.slip : colour)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(filled ? colour : .clear)
                )
                .overlay(Capsule().strokeBorder(colour, lineWidth: filled ? 0 : 1.2))
        }
        .buttonStyle(.plain)
    }
}

/// Work with no measurable progress.
///
/// Deliberately not a bar: a bar implies a fraction, and waiting for a port
/// does not have one. Three dots pulsing says "still going" without claiming
/// how far along it is.
struct WorkingPulse: View {
    var colour: Color
    @State private var bright = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(colour)
                    .frame(width: 5, height: 5)
                    .opacity(bright ? 0.95 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.62)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.16),
                        value: bright
                    )
            }
            Spacer()
        }
        .frame(height: 5)
        .onAppear { bright = true }
    }
}
