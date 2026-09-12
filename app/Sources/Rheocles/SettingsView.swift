import RheoclesCore
import SwiftUI

/// Settings, in place of the stream list (spec §12): output root, codec,
/// show windows, the bearer token as a pairing code.
///
/// Every row says whose setting it is. Codec and show windows are the
/// app's and take effect at once; the output root and the token are the
/// daemon's, shown as they are and changed only through the API — and the
/// two commands that would change them are not in the protocol yet, so
/// those controls say so rather than pretend.
struct SettingsView: View {
    @Bindable var daemon: DaemonModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Output root") {
                HStack(spacing: 8) {
                    Text(
                        daemon.discovery.map { MenuBarView.abbreviate($0.outputRoot) } ?? "··"
                    )
                    .font(Type.mono(10.5))
                    .foregroundStyle(daemon.discovery == nil ? Brand.script : Brand.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    Spacer(minLength: 4)
                    PillButton("Reveal", colour: Brand.aegean, filled: false) {
                        daemon.revealOutputRoot()
                    }
                    .disabled(daemon.discovery == nil)
                }
                if DaemonModel.outputRootPath == nil {
                    note(
                        "Set with rheocles-core --output-root. Changing it over the API is not in the protocol yet."
                    )
                }
            }
            rule
            row("Codec") {
                Segmented(
                    options: [(Manifest.Codec.hevc, "HEVC"), (.prores, "ProRes 422")],
                    selection: Binding(get: { daemon.codec }, set: { daemon.codec = $0 }))
                note(
                    "One setting for the whole take, sent with every Record. Video only; audio is always Broadcast Wave."
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
                    PillButton("Rotate", colour: Brand.script, filled: false) {}
                        .disabled(true)
                }
                note(
                    "The bearer token, from \(MenuBarView.abbreviate(daemon.tokenFile.path)). "
                        + "Rotating it is the daemon's job and not in the protocol yet.")
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
