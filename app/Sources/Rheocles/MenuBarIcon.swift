import AppKit
import SwiftUI

/// The menu bar icon, rasterised from the mark as a template image.
///
/// Sonocles' pattern, for Sonocles' reasons. A SwiftUI view handed straight
/// to `MenuBarExtra`'s label inherits no foreground style in that context, so
/// a shape drawn with bare `stroke()` renders with no colour at all — the app
/// launches, takes a menu bar slot, and appears to be missing entirely. And
/// even coloured explicitly it would be *a* colour, which is wrong: the menu
/// bar inverts between light and dark, and anything that is not a template
/// image stays put while everything around it flips.
///
/// So each state is rendered once to an `NSImage` with `isTemplate = true`.
/// macOS then uses only the alpha channel and tints it to match the bar. The
/// dimmed idle state survives that because dimming is opacity — which is
/// alpha, which is exactly what a template keeps.
///
/// Three states (spec §12, BRAND § Mark): idle dims the whole mark to 40 %,
/// armed draws the streams in outline, recording fills them. Whole-mark
/// dimming rather than per-stroke because per-stroke reads at 64 pt in a
/// review and not at 18 pt in a menu bar, which is the only size that counts.
@MainActor
enum MenuBarIcon {
    enum State: Hashable {
        case idle
        case armed
        case recording(lateJoined: Set<Int>)

        static let recording = State.recording(lateJoined: [])
    }

    private static var cache: [State: NSImage] = [:]

    static func image(for state: State) -> NSImage {
        if let cached = cache[state] { return cached }
        let image = render(state)
        cache[state] = image
        return image
    }

    /// 18 pt is the conventional menu bar glyph size; rendering at 2x and
    /// declaring the point size keeps it crisp on Retina without doubling on
    /// non-Retina.
    private static func render(_ state: State) -> NSImage {
        let side: CGFloat = 18

        let mark: RheoclesMark
        let opacity: Double
        switch state {
        case .idle:
            mark = RheoclesMark(streams: .solid, weight: 3.2)
            opacity = 0.4
        case .armed:
            mark = RheoclesMark(streams: .outline, weight: 3.2)
            opacity = 1
        case .recording(let late):
            mark = RheoclesMark(streams: .solid, lateJoined: late, weight: 3.2)
            opacity = 1
        }

        let renderer = ImageRenderer(
            content:
                mark
                .foregroundStyle(.black)
                .opacity(opacity)
                .frame(width: side, height: side)
        )
        renderer.scale = 2

        guard let image = renderer.nsImage else {
            // Never expected, but an invisible menu bar item is precisely the
            // failure this file exists to prevent, so fall back to something
            // that definitely draws.
            let fallback =
                NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Rheocles")
                ?? NSImage()
            fallback.isTemplate = true
            return fallback
        }

        image.size = NSSize(width: side, height: side)
        image.isTemplate = true
        return image
    }
}
