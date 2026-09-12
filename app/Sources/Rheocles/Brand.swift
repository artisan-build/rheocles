import SwiftUI

/// The palette, by role.
///
/// `docs/BRAND.md` is the source and names the pigments; this file names the
/// roles so a view never says "ochre" and a palette change stays here. The app
/// is the dark half of the family — limestone is the site's ground, these are
/// the "dark blocks on the light page" — and Sono and Rheo share every one of
/// them except the signature, which is Aegean here and terracotta there.
enum Brand {
    // grounds
    /// Deepest ground — behind everything.
    static let slip = Color(hex: 0x100C0A)
    /// The popover itself.
    static let panel = Color(hex: 0x1C1611)
    /// Insets, meter cells, rules.
    static let field = Color(hex: 0x2B211A)

    // text
    /// Brightest text: the wordmark, values that matter.
    static let bone = Color(hex: 0xEFE3D0)
    /// Body text.
    static let body = Color(hex: 0xCDBBA3)
    /// A value we do not have. Load-bearing: an unmeasured level, a stream
    /// with no frames yet, a daemon that has not answered. Absence gets its
    /// own colour so it is never mistaken for a number.
    static let script = Color(hex: 0x7A6A59)

    // states — a small language the icon and the popover both speak
    /// The signature on dark: aegean, brightened to read on panel.
    static let aegean = Color(hex: 0x6FA3D6)
    /// Armed: live, holding its device, costing you. Fills and marks only.
    static let ochre = Color(hex: 0xC9903A)
    /// Recording, stop, and a daemon that is down.
    static let oxide = Color(hex: 0xB4453A)
    /// Complete, healthy, answering.
    static let verdigris = Color(hex: 0x7FA88C)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// Type roles. The brand faces — Fraunces, Instrument Sans, IBM Plex Mono —
/// are web fonts the site fetches from Google and are not installed on a
/// user's Mac, so the app stands in with the system faces of the same
/// character: a serif for the wordmark, the system sans for body, monospaced
/// for anything that is a number. Bundling the real faces is a design move
/// to propose, not to make quietly.
enum Type {
    static func wordmark(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .serif)
    }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Kickers: mono, uppercase, letterspaced — furniture, never competing
    /// with what sits beneath.
    static func kicker(_ size: CGFloat = 9) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}
