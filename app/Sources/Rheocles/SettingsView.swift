import RheoclesCore
import SwiftUI

/// Settings, in place of the stream list (spec §12): output root, codec,
/// show windows, the bearer token as a pairing code.
///
/// Every row says whose setting it is. The output root, the codec and the
/// token are the daemon's, changed over `PATCH /settings` and
/// `POST /token/rotate` and shown as the daemon last answered; show
/// windows is the app's. A refusal — the root cannot move under an active
/// take — is shown in the daemon's words beneath the rows.
struct SettingsView: View {
    @Bindable var daemon: DaemonModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Output root") {
                HStack(spacing: 8) {
                    Text(daemon.settings.map { MenuBarView.abbreviate($0.outputRoot) } ?? "··")
                        .font(Type.mono(10.5))
                        .foregroundStyle(daemon.settings == nil ? Brand.script : Brand.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    PillButton("Change…", colour: Brand.aegean, filled: false) {
                        daemon.chooseOutputRoot()
                    }
                    .disabled(daemon.settings == nil || Preview.isRendering)
                    FinderButton { daemon.revealOutputRoot() }
                        .disabled(daemon.settings == nil)
                }
                note("Where new takes land. Cannot move while a take is active.")
            }
            rule
            row("Codec") {
                Segmented(
                    options: [(Manifest.Codec.hevc, "HEVC"), (.prores, "ProRes 422")],
                    selection: Binding(
                        get: { daemon.codec }, set: { daemon.updateSettings(codec: $0) }))
                note(
                    "The daemon's default for every take. Video only; audio is always Broadcast Wave."
                )
            }
            rule
            row("Windows") {
                Button {
                    daemon.showWindows.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Checkbox(on: daemon.showWindows)
                        Text("Show windows in the stream list")
                            .font(Type.body(11))
                            .foregroundStyle(Brand.inkSoft)
                    }
                }
                .buttonStyle(.plain)
                note("Long and volatile, so hidden unless asked for.")
            }
            rule
            row("Pairing code") {
                HStack(spacing: 8) {
                    Text(
                        daemon.token.map { daemon.tokenShown ? $0 : (daemon.maskedToken ?? $0) }
                            ?? "··"
                    )
                    .font(Type.mono(daemon.tokenShown ? 8.5 : 10.5))
                    .foregroundStyle(daemon.token == nil ? Brand.script : Brand.ink)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    Spacer(minLength: 4)
                    PillButton(
                        daemon.tokenShown ? "Hide" : "Show", colour: Brand.aegean, filled: false
                    ) {
                        daemon.tokenShown.toggle()
                    }
                    PillButton("Copy", colour: Brand.aegean, filled: false) { daemon.copyToken() }
                    PillButton(
                        daemon.rotateArmed ? "Rotate now" : "Rotate", colour: Brand.oxide,
                        filled: daemon.rotateArmed
                    ) { daemon.rotateToken() }
                }
                note(
                    daemon.rotateArmed
                        ? "Click again to rotate. Every other paired client loses access until it reads the new token from the file."
                        : "The bearer token, from \(MenuBarView.abbreviate(daemon.tokenFile.path)). Rotating invalidates the old one at once."
                )
            }
            if let error = daemon.settingsError {
                Text(error)
                    .font(Type.mono(9.5))
                    .foregroundStyle(Brand.oxide)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .padding(.vertical, 4)
    }

    private var rule: some View {
        Rectangle().fill(Brand.line).frame(height: 1).padding(.horizontal, 14)
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeading(title).padding(.horizontal, -14).padding(.top, -9)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Type.body(10))
            .foregroundStyle(Brand.inkFaint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A two-way choice drawn from shapes: the site's pill, split.
struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Button {
                    selection = value
                } label: {
                    Text(label)
                        .font(Type.body(11, .semibold))
                        .foregroundStyle(on ? Brand.ground : Brand.aegean)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(on ? Brand.aegean : .clear)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Brand.aegean, lineWidth: 1.2))
    }
}
