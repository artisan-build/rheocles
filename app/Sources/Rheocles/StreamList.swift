import AppKit
import RheoclesCore
import SwiftUI

/// Every stream, grouped by kind in the daemon's order, each with its arm
/// switch. Armed is unmistakable: the row's name, its switch and a bar down
/// its left edge all go ochre — the colour of a device that is live, held,
/// and costing CPU — so nobody leaves six cameras live overnight by accident
/// (spec §6).
struct StreamList: View {
    let daemon: DaemonModel

    /// The list's natural height. A ScrollView in a MenuBarExtra window has
    /// no height of its own and collapses to nothing; it is sized to its
    /// content up to the cap, and scrolls beyond it.
    @State private var contentHeight: CGFloat = 0

    private var sections: [(StreamInfo.Kind, [StreamInfo])] {
        let visible = daemon.visibleStreams
        return StreamInfo.Kind.allCases.compactMap { kind in
            let members = visible.filter { $0.kind == kind }
            return members.isEmpty && nudge(for: kind) == nil ? nil : (kind, members)
        }
    }

    var body: some View {
        // `ImageRenderer` draws an NSScrollView-backed ScrollView as nothing
        // at all, so --render-preview lays the whole list out flat — which is
        // also what a design review wants to see. On screen it scrolls.
        if Preview.isRendering {
            list
        } else {
            ScrollView(.vertical) {
                list.onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    contentHeight = $0
                }
            }
            .frame(height: min(contentHeight, 392))
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element.0) { index, section in
                let (kind, members) = section
                HStack {
                    SectionHeading(kind.heading)
                    Spacer()
                    if index == 0, daemon.disarmPlacement == .kicker, !daemon.armedStreams.isEmpty {
                        DisarmAllButton(daemon: daemon)
                            .padding(.trailing, 14)
                            .padding(.top, 5)
                    }
                }
                ForEach(members) { stream in
                    StreamRow(stream: stream, daemon: daemon)
                    if daemon.previewing == stream.id, stream.capabilities.video != nil {
                        PreviewPane(daemon: daemon)
                    }
                }
                if let nudge = nudge(for: kind) {
                    nudge
                }
            }
            if daemon.streams.isEmpty && daemon.permissions == nil {
                Text("No answer to GET /streams yet.")
                    .font(Type.body(10.5))
                    .foregroundStyle(Brand.script)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .padding(.vertical, 4)
    }

    /// What macOS has not let the daemon do, said where the missing streams
    /// would be. `GET /streams` reports it for exactly this (PROTOCOL).
    private func nudge(for kind: StreamInfo.Kind) -> PermissionNudge? {
        guard let permissions = daemon.permissions else { return nil }
        switch kind {
        case .display where permissions.screen != .authorized:
            return PermissionNudge(
                capability: "Screen Recording", status: permissions.screen,
                consequence: daemon.startedByUs
                    ? "displays and windows are not listed; the daemon restarts once granted"
                    : "displays and windows are not listed; grant it, then relaunch the daemon",
                pane: "Privacy_ScreenCapture")
        case .camera where permissions.camera == .denied || permissions.camera == .restricted:
            return PermissionNudge(
                capability: "Camera", status: permissions.camera,
                consequence: "arming a camera will fail", pane: "Privacy_Camera")
        case .microphone
        where permissions.microphone == .denied || permissions.microphone == .restricted:
            return PermissionNudge(
                capability: "Microphone", status: permissions.microphone,
                consequence: "arming a microphone will fail", pane: "Privacy_Microphone")
        default:
            return nil
        }
    }
}

struct SectionHeading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(Type.kicker())
            .kerning(1.1)
            .foregroundStyle(Brand.aegean)
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, 4)
    }
}

struct StreamRow: View {
    let stream: StreamInfo
    let daemon: DaemonModel

    /// The switch shows what was asked for until the daemon has answered.
    private var shownArmed: Bool {
        if let pending = daemon.pending, pending.id == stream.id { return pending.armed }
        return stream.armed
    }

    private var isPending: Bool {
        daemon.pending?.id == stream.id
    }

    /// In the active take and writing: the bar goes oxide. Armed but not
    /// in the take (it was armed after the cue) stays ochre.
    private var writing: Bool {
        guard let take = daemon.take, take.isRecording else { return false }
        return take.writing.contains { $0.id == stream.id }
    }

    private var recording: Bool { daemon.take?.isRecording == true }
    private var stalled: Bool { daemon.stalled.contains(stream.id) }

    /// While writing: frames written and measured drift, from the last
    /// `levels` event. Drift absent is `··`, never zero.
    private var liveDetail: String? {
        guard writing, let status = daemon.streamStatus[stream.id] else { return nil }
        let drift = status.drift.map { String(format: "%+.0f ms", $0 * 1000) } ?? "··"
        // Audio counts sample frames: say it as time, the way a recorder does.
        if let audio = stream.capabilities.audio, audio.sampleRate > 0 {
            let seconds = Double(status.framesWritten) / audio.sampleRate
            return "\(seconds.clock) · \(drift)"
        }
        return "\(status.framesWritten) fr · \(drift)"
    }

    var body: some View {
        HStack(spacing: 9) {
            Rectangle()
                .fill(writing ? Brand.oxide : shownArmed ? Brand.ochre : .clear)
                .frame(width: 3)

            Image(systemName: stream.kind.symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(shownArmed ? Brand.ochreInk : Brand.inkFaint)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(stream.name)
                    .font(Type.body(11.5, shownArmed ? .semibold : .medium))
                    .foregroundStyle(shownArmed ? Brand.ochreInk : Brand.ink)
                    .lineLimit(1)
                // The meter shares the detail line until the row is writing,
                // when the numbers need the width and the meter takes a
                // third line: a writing audio row is twelve points taller.
                let meterInline = writing == false
                HStack(spacing: 8) {
                    Text(liveDetail ?? detail)
                        .font(Type.mono(9.5))
                        .foregroundStyle(Brand.inkFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if stalled {
                        Text("STALLED")
                            .font(Type.kicker(8))
                            .kerning(0.8)
                            .foregroundStyle(Brand.ground)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Brand.oxide))
                    }
                    // Levels flow only while armed; before the first
                    // reading the meter is empty and the number is absent.
                    if meterInline, stream.capabilities.audio != nil,
                        stream.armed || daemon.previewing == stream.id
                    {
                        LevelMeter(db: daemon.levels[stream.id])
                    }
                }
                if !meterInline, stream.capabilities.audio != nil {
                    LevelMeter(db: daemon.levels[stream.id])
                }
            }
            // The name and its numbers get their width before the spacer
            // does; the controls on the right are fixed-size anyway.
            .layoutPriority(1)

            Spacer(minLength: 8)

            // While recording, the API's join and leave (spec §6) are here
            // too — principle 1, everything reachable from both. Leave keeps
            // the stream armed; join arms a cold stream first.
            if recording {
                if writing {
                    PillButton("Leave", colour: Brand.oxide, filled: false, compact: true) {
                        daemon.leave(stream.id)
                    }
                    .disabled(daemon.takeBusy)
                } else {
                    PillButton("Join", colour: Brand.ochreInk, filled: false, compact: true) {
                        daemon.join(stream.id)
                    }
                    .disabled(daemon.takeBusy)
                }
            }

            // The eye: a frame for video, a sampled level for audio.
            PreviewButton(
                on: daemon.previewing == stream.id, audio: stream.capabilities.video == nil
            ) {
                daemon.togglePreview(stream.id)
            }

            ArmSwitch(on: shownArmed, pending: isPending) {
                daemon.arm(stream.id, !shownArmed)
            }
            .padding(.trailing, 14)
        }
        .frame(height: writing && stream.capabilities.audio != nil ? 42 : 30)
        .contentShape(Rectangle())
    }

    /// Capabilities, and for a window the owning app — the name alone
    /// ("Docs") says nothing about which of forty windows it is.
    private var detail: String {
        stream.kind == .window
            ? "\(stream.model) · \(stream.capabilities.summary)"
            : stream.capabilities.summary
    }
}

/// The arm switch, drawn from shapes.
///
/// A system `Toggle` is AppKit-backed — invisible to `--render-preview` and
/// the accent colour of whatever the user picked, when this one has to be
/// ochre and nothing else. A capsule and a knob are eleven lines.
struct ArmSwitch: View {
    let on: Bool
    let pending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule()
                    .fill(on ? Brand.ochre : Brand.sink)
                    .overlay(
                        Capsule().strokeBorder(
                            on ? Brand.ochre : Brand.line, lineWidth: 1))
                Circle()
                    .fill(on ? Brand.ground : Brand.script)
                    .padding(2.5)
            }
            .frame(width: 30, height: 17)
            .opacity(pending ? 0.55 : 1)
            .animation(.easeOut(duration: 0.15), value: on)
        }
        .buttonStyle(.plain)
        .disabled(pending)
        .accessibilityLabel(on ? "Disarm" : "Arm")
    }
}

/// A grant that is missing, and the one click that fixes it.
struct PermissionNudge: View {
    let capability: String
    let status: Permissions.Status
    let consequence: String
    let pane: String

    private var statusWord: String {
        switch status {
        case .authorized: "granted"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not asked yet"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(capability): \(statusWord) — \(consequence).")
                .font(Type.body(10.5))
                .foregroundStyle(Brand.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            PillButton("Open Privacy settings", colour: Brand.aegean, filled: false) {
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
                {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

/// The eye: preview this stream, one at a time.
struct PreviewButton: View {
    let on: Bool
    var audio = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: audio ? (on ? "ear.fill" : "ear") : (on ? "eye.fill" : "eye"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(on ? Brand.aegean : Brand.inkFaint)
                .frame(width: 22, height: 17)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? Brand.wash : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Stop preview" : "Preview")
    }
}

/// The preview frame, under the row it belongs to. 16:9 at the popover's
/// width; a frame of another shape letterboxes on the code-block ground.
struct PreviewPane: View {
    let daemon: DaemonModel

    var body: some View {
        ZStack {
            Rectangle().fill(Brand.Block.panel)
            if let frame = daemon.previewFrame {
                Image(nsImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let error = daemon.previewError {
                Text(error)
                    .font(Type.mono(9.5))
                    .foregroundStyle(Brand.oxide)
                    .multilineTextAlignment(.center)
                    .padding(12)
            } else {
                Text("waiting for a frame")
                    .font(Type.mono(9.5))
                    .foregroundStyle(Brand.script)
            }
        }
        .frame(width: 316, height: 178)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

/// Twelve cells over the useful range, in the row.
///
/// Below −60 dBFS is silence for our purposes and clipping pins at the top,
/// so the bar reads the way a console meter does. No reading yet is no
/// cells and `··`, never an empty bar pretending to be silence.
struct LevelMeter: View {
    let db: Double?

    private var filled: Int {
        guard let db else { return 0 }
        return max(0, min(12, Int(((db + 60) / 60) * 12)))
    }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 1.5) {
                ForEach(0..<12, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(colour(for: index))
                        .frame(width: 4, height: 8)
                }
            }
            Text(db.map { String(format: "%.0f", $0) } ?? "··")
                .font(Type.mono(9))
                .foregroundStyle(db == nil ? Brand.script : Brand.inkFaint)
                .frame(width: 22, alignment: .trailing)
        }
    }

    private func colour(for index: Int) -> Color {
        guard index < filled else { return Brand.sink }
        return index >= 11 ? Brand.oxide : Brand.ochre
    }
}
