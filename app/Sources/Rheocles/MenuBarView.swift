import RheoclesCore
import SwiftUI

/// The popover behind the menu bar icon.
///
/// Header, a centre panel with exactly one state showing, controls beneath.
/// The centre is the stream list when the daemon is up — every stream with
/// its arm switch, armed unmistakable in ochre — and the daemon's condition
/// when it is not. The Record button and the settings arrive with the takes
/// (tasks 3–4) in the same grid.
///
/// Styled as rheocles.com is: limestone ground, ink, the Aegean signature,
/// and a 4 pt Aegean rule along the top — the site header's `border-top` —
/// so the popover and the site open the same way. Dark is for the daemon's
/// data strip only, the way the site's code blocks are dark.
struct MenuBarView: View {
    @Bindable var daemon: DaemonModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Brand.aegean).frame(height: 4)
            header
            rule
            centre
            rule
            controls
        }
        .frame(width: 344)
        .background(Brand.ground)
        // The pulse is every three seconds; the list should be current the
        // moment it is looked at.
        .task { await daemon.check() }
    }

    private var rule: some View {
        Rectangle().fill(Brand.line).frame(height: 1)
    }

    // MARK: - header

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            RheoclesMark(
                streams: armedCount > 0 && !recording ? .outline : .solid,
                lateJoined: recording ? daemon.take?.lateJoined ?? [] : [],
                cueDot: recording, weight: 3.4
            )
            .foregroundStyle(markColour)
            .frame(width: 20, height: 20)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Rheocles")
                    .font(Type.wordmark(15))
                    .foregroundStyle(Brand.ink)
                Text("REE-oh-kleez")
                    .font(Type.mono(9))
                    .foregroundStyle(Brand.inkFaint)
            }

            Spacer()

            StatePill(label: stateLabel, colour: stateColour)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var armedCount: Int {
        daemon.status == .running ? daemon.armedStreams.count : 0
    }

    private var recording: Bool {
        daemon.status == .running && daemon.take?.isRecording == true
    }

    private var markColour: Color {
        switch daemon.status {
        case .running: recording ? Brand.oxide : armedCount > 0 ? Brand.ochre : Brand.aegean
        case .launching: Brand.aegean.opacity(0.5)
        case .down: Brand.script
        }
    }

    private var stateLabel: String {
        switch daemon.status {
        case .running:
            if recording { return "Recording" }
            return armedCount > 0 ? "Armed · \(armedCount)" : "Idle"
        case .launching: return "Launching"
        case .down: return "Down"
        }
    }

    private var stateColour: Color {
        switch daemon.status {
        case .running: recording ? Brand.oxide : armedCount > 0 ? Brand.ochreInk : Brand.script
        case .launching: Brand.aegean
        case .down: Brand.oxide
        }
    }

    // MARK: - centre

    @ViewBuilder private var centre: some View {
        switch daemon.status {
        case .running:
            VStack(spacing: 0) {
                StreamList(daemon: daemon)
                rule
                TakeBar(daemon: daemon)
                daemonStrip
            }
        case .launching:
            launching.modifier(CentrePanel())
        case .down(let why):
            down(why).modifier(CentrePanel())
        }
    }

    /// `GET /` under the streams: the daemon is answering, its version, whose
    /// it is, how much room there is, and where files go.
    private var daemonStrip: some View {
        let d = daemon.discovery
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(Brand.Block.aegean).frame(width: 5, height: 5)
                Text("rheocles-core \(d?.version ?? "··")")
                    .foregroundStyle(Brand.Block.bone)
                Text("·")
                Text(daemon.startedByUs ? "ours" : "shared")
                Text("·")
                Text(d?.freeBytes.map { "\(Self.bytes($0)) free" } ?? "free ··")
                    .foregroundStyle(d?.freeBytes == nil ? Brand.script : Brand.Block.bone)
            }
            HStack(spacing: 6) {
                Text("→")
                Text(d.map { Self.abbreviate($0.outputRoot) } ?? "··")
                    .truncationMode(.middle)
            }
            .padding(.leading, 11)
        }
        .lineLimit(1)
        .font(Type.mono(9.5))
        .foregroundStyle(Brand.Block.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Brand.Block.panel)
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
            .foregroundStyle(Brand.inkFaint)
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
                .foregroundStyle(Brand.inkSoft)
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

    private func kicker(_ label: String) -> some View {
        Text(label.uppercased())
            .font(Type.kicker())
            .kerning(1.1)
            .foregroundStyle(Brand.aegean)
            .frame(width: 58, alignment: .leading)
    }

    // MARK: - controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // An arm call the daemon refused, in the daemon's words. Cleared
            // by the next call; the list itself is already re-read and true.
            if let error = daemon.takeError ?? daemon.armError ?? daemon.streamsError {
                Text(error)
                    .font(Type.mono(9.5))
                    .foregroundStyle(Brand.oxide)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    daemon.showWindows.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Checkbox(on: daemon.showWindows)
                        Text("Show windows")
                            .font(Type.body(11))
                            .foregroundStyle(Brand.inkSoft)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                PillButton("Quit", colour: Brand.aegean, filled: false) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - formatting

    /// Decimal units, one decimal: what Finder says, to the digit that
    /// matters for "is there room for this take".
    static func bytes(_ count: Int64) -> String {
        let gb = Double(count) / 1_000_000_000
        if gb >= 1000 { return String(format: "%.2f TB", gb / 1000) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", gb * 1000)
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
    var glyph: String?
    let action: () -> Void

    init(
        _ label: String, colour: Color, filled: Bool, glyph: String? = nil,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.colour = colour
        self.filled = filled
        self.glyph = glyph
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let glyph {
                    Image(systemName: glyph).font(.system(size: 7, weight: .bold))
                }
                Text(label)
            }
            .font(Type.body(11, .semibold))
            .foregroundStyle(filled ? Brand.ground : colour)
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

/// The centre panel's frame for the states that are prose rather than a list.
struct CentrePanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Brand.inset)
    }
}

/// A checkbox from shapes, for the same reason as the switch.
struct Checkbox: View {
    let on: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(on ? Brand.aegean : Brand.ground)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(on ? Brand.aegean : Brand.script, lineWidth: 1))
            if on {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Brand.ground)
            }
        }
        .frame(width: 13, height: 13)
    }
}

/// Record or Stop, the take's name, and the time since the cue.
///
/// One button (spec §12). Record is `POST /record` — create and start in
/// one — and is only offered when something is armed, because a take with
/// no streams is a folder with a manifest in it. While recording the bar
/// turns oxide and counts; afterwards it says what the take became, in
/// olive if complete and oxide with the reason if not.
struct TakeBar: View {
    @Bindable var daemon: DaemonModel

    private var take: Manifest? { daemon.take }
    private var recording: Bool { take?.isRecording == true }
    private var canRecord: Bool { !daemon.armedStreams.isEmpty && !daemon.takeBusy }

    var body: some View {
        HStack(spacing: 10) {
            if recording {
                PillButton("Stop", colour: Brand.oxide, filled: true, glyph: "stop.fill") {
                    daemon.stop()
                }
                .disabled(daemon.takeBusy)
                live
            } else {
                PillButton(
                    "Record", colour: canRecord ? Brand.oxide : Brand.script,
                    filled: canRecord, glyph: "circle.fill"
                ) {
                    daemon.record()
                }
                .disabled(!canRecord)
                if daemon.armedStreams.isEmpty {
                    Text(take.map { _ in "" } ?? "Arm a stream to record.")
                        .font(Type.body(10.5))
                        .foregroundStyle(Brand.script)
                }
                if let take, take.isOver {
                    finished(take)
                } else if !daemon.armedStreams.isEmpty {
                    nameField
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(recording ? Brand.oxide.opacity(0.08) : Brand.inset)
    }

    /// The name for the next take. Empty means the daemon names it.
    ///
    /// An NSTextField underneath, so `--render-preview` cannot draw it and
    /// shows a drawn stand-in instead; on screen it is a real field.
    @ViewBuilder private var nameField: some View {
        if Preview.isRendering {
            Text(daemon.takeName.isEmpty ? "take name" : daemon.takeName)
                .font(Type.mono(10.5))
                .foregroundStyle(daemon.takeName.isEmpty ? Brand.script : Brand.ink)
                .modifier(FieldChrome())
        } else {
            TextField(
                text: $daemon.takeName, prompt: Text("take name").foregroundStyle(Brand.script)
            ) { EmptyView() }
            .textFieldStyle(.plain)
            .font(Type.mono(10.5))
            .foregroundStyle(Brand.ink)
            .onSubmit { if canRecord { daemon.record() } }
            .modifier(FieldChrome())
        }
    }

    private var live: some View {
        HStack(spacing: 8) {
            Text(take?.take.name ?? "··")
                .font(Type.body(11.5, .semibold))
                .foregroundStyle(Brand.ink)
                .lineLimit(1)
            Text(take?.elapsed(at: daemon.now)?.clock ?? "··:··")
                .font(Type.mono(12, .medium))
                .foregroundStyle(Brand.oxide)
                .monospacedDigit()
            Text("\(take?.writing.count ?? 0) writing")
                .font(Type.mono(9.5))
                .foregroundStyle(Brand.inkFaint)
        }
    }

    private func finished(_ take: Manifest) -> some View {
        let complete = take.take.state == "complete"
        let tone = complete ? Brand.olive : Brand.oxide
        // One Text, so it truncates as one line rather than word by word.
        var line =
            Text(take.take.name ?? take.take.id).foregroundColor(Brand.inkSoft) + Text(" · ")
            + Text(take.take.state ?? "··").foregroundColor(tone)
        if let elapsed = take.elapsed(at: daemon.now) {
            line = line + Text(" · \(elapsed.clock)")
        }
        line = line + Text(" · \(take.streams.count) files")
        if let reason = take.take.reason {
            line = line + Text(" — \(reason)").foregroundColor(Brand.oxide)
        }
        return HStack(spacing: 6) {
            Circle().fill(tone).frame(width: 5, height: 5)
            line
                .font(Type.mono(9.5))
                .foregroundStyle(Brand.inkFaint)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct FieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Brand.ground))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.line, lineWidth: 1))
    }
}
