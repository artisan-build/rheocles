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
            ForEach(sections, id: \.0) { kind, members in
                SectionHeading(kind.heading)
                ForEach(members) { stream in
                    StreamRow(stream: stream, daemon: daemon)
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
                consequence: "displays and windows are not listed",
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

    var body: some View {
        HStack(spacing: 9) {
            Rectangle()
                .fill(shownArmed ? Brand.ochre : .clear)
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
                Text(detail)
                    .font(Type.mono(9.5))
                    .foregroundStyle(Brand.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            ArmSwitch(on: shownArmed, pending: isPending) {
                daemon.arm(stream.id, !shownArmed)
            }
            .padding(.trailing, 14)
        }
        .frame(height: 30)
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
