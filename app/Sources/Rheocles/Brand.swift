import AppKit
import SwiftUI

/// The palette, by role.
///
/// `docs/BRAND.md` is the source and names the pigments; this file names the
/// roles so a view never says "ochre" and a palette change stays here. The
/// popover is the site: limestone ground, ink text, the Aegean signature,
/// and the state colours — ochre armed, oxide recording, olive complete,
/// script for a value we do not have. Dark is for data blocks only, the way
/// the site's code blocks are dark on the limestone page.
enum Brand {
    // ground — the plaster
    static let ground = Color(hex: 0xFAF2E4)
    static let inset = Color(hex: 0xEFE5D2)
    static let sink = Color(hex: 0xE0D4BE)
    static let line = Color(hex: 0xDED0B8)

    // ink
    static let ink = Color(hex: 0x2A211A)
    static let inkSoft = Color(hex: 0x4E4034)
    static let inkFaint = Color(hex: 0x6B5C4C)

    // the signature — Aegean blue on lime plaster
    static let aegean = Color(hex: 0x2E5C86)
    static let aegeanSoft = Color(hex: 0x5F8FB8)
    static let aegeanDeep = Color(hex: 0x244A6B)
    static let wash = Color(hex: 0xE4ECF3)

    // states — a small language the icon and the popover both speak
    /// Armed: live, holding its device, costing you. Fills and marks only.
    static let ochre = Color(hex: 0xC9903A)
    /// Armed, as text.
    static let ochreInk = Color(hex: 0x8A5E1A)
    /// Recording, stop, and a daemon that is down.
    static let oxide = Color(hex: 0xB4453A)
    /// Complete, healthy, answering.
    static let olive = Color(hex: 0x6E7A52)
    /// A value we do not have. Load-bearing: an unmeasured level, a stream
    /// with no frames yet, a daemon that has not answered. Absence gets its
    /// own colour so it is never mistaken for a number.
    static let script = Color(hex: 0x7A6A59)

    /// Dark blocks on the light page — the site's code blocks, and here the
    /// daemon's data strip. Nowhere else.
    enum Block {
        static let panel = Color(hex: 0x1C1611)
        static let field = Color(hex: 0x2B211A)
        static let bone = Color(hex: 0xEFE3D0)
        static let body = Color(hex: 0xCDBBA3)
        static let aegean = Color(hex: 0x6FA3D6)
    }
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

/// Type roles, in the family's faces.
///
/// Fraunces, Instrument Sans and IBM Plex Mono — the same three the site
/// loads from Google — ship in the bundle under the OFL (`Fonts/`, licences
/// beside them) and are registered for this process at launch. Fraunces is
/// used the way the site uses it: `SOFT 30`, `WONK 1`, weight 700, so the
/// wordmark reads as drawn rather than defaulted. Every role falls back to
/// the system face of the same character if registration fails, because a
/// popover with no text is worse than one in the wrong font.
enum Type {
    static func wordmark(_ size: CGFloat) -> Font {
        variable(
            "Fraunces", size: size,
            axes: [Axis.weight: 700, Axis.soft: 30, Axis.wonk: 1, Axis.opticalSize: 24],
            fallback: .system(size: size, weight: .bold, design: .serif))
    }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        variable(
            "Instrument Sans", size: size, axes: [Axis.weight: Self.wght(weight)],
            fallback: .system(size: size, weight: weight))
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name = weight == .regular ? "IBMPlexMono-Regular" : "IBMPlexMono-Medium"
        guard registered, let nsFont = NSFont(name: name, size: size) else {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return Font(nsFont)
    }
    /// Kickers: mono, uppercase, letterspaced — furniture, never competing
    /// with what sits beneath.
    static func kicker(_ size: CGFloat = 9) -> Font {
        mono(size, .medium)
    }

    /// OpenType variation axis tags, as CoreText wants them.
    private enum Axis {
        static let weight: UInt32 = 0x7767_6874  // wght
        static let soft: UInt32 = 0x534F_4654  // SOFT
        static let wonk: UInt32 = 0x574F_4E4B  // WONK
        static let opticalSize: UInt32 = 0x6F70_737A  // opsz
    }

    private static func wght(_ weight: Font.Weight) -> Double {
        switch weight {
        case .medium: 500
        case .semibold: 600
        case .bold, .heavy, .black: 700
        default: 400
        }
    }

    private static func variable(
        _ family: String, size: CGFloat, axes: [UInt32: Double], fallback: Font
    ) -> Font {
        guard registered else { return fallback }
        var variation: [NSNumber: NSNumber] = [:]
        for (tag, value) in axes { variation[NSNumber(value: tag)] = NSNumber(value: value) }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String): variation,
        ])
        guard let nsFont = NSFont(descriptor: descriptor, size: size),
            nsFont.familyName == family
        else { return fallback }
        return Font(nsFont)
    }

    /// Register every face in `Fonts/` for this process, once. In the bundle
    /// that is `Contents/Resources/Fonts`; straight out of `swift build` it
    /// is the source directory, so `--render-preview` renders in the real
    /// faces on the machine that built it.
    static let registered: Bool = {
        let candidates = [
            Bundle.main.resourceURL?.appending(path: "Fonts"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fonts"),
        ]
        guard
            let directory = candidates.compactMap({ $0 }).first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }),
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return false }

        var any = false
        for url in files where url.pathExtension == "ttf" {
            // An "already registered" error is fine; a face is a face.
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) { any = true }
        }
        return any
    }()
}
