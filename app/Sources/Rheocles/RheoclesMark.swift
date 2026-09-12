import SwiftUI

/// The mark: strokes struck from one bar.
///
/// A single vertical stroke — the cue — with four horizontal strokes flowing
/// right from it, staggered in length, with a slight hand-made waver rather
/// than ruled. A river braid, a multitrack timeline, and "one cue, many files"
/// in one drawing. The strokes never merge; that is the point.
///
/// The geometry is the site's `site/src/components/Mark.astro`, verbatim, on
/// a 32-unit box, so the menu bar and rheocles.com draw the same shape.
/// Drawn rather than shipped as an asset because it is five strokes, and a
/// vector that scales exactly beats a PDF that needs a build step.
///
/// Three renderings, from `docs/BRAND.md` § Mark: the streams solid (idle,
/// which the icon then dims as a whole; and recording), or as outlines
/// (armed — live, not yet writing). The bar is the cue and stays solid in
/// every state; it is not a stream. A late-joined stream is a shorter stroke
/// that starts to the right of the bar, so the icon can tell the truth about
/// the take without the popover being opened.
struct RheoclesMark: View {
    enum Streams {
        case solid
        case outline
    }

    var streams: Streams = .solid
    /// Indices (0–3, top to bottom) of streams that joined late.
    var lateJoined: Set<Int> = []
    /// Stroke width in points at 32 pt; scales with the mark.
    var weight: CGFloat = 3

    /// The four streams: start x, control points, end. `lateStart` is where
    /// the stroke begins when that stream joined late.
    private static let strokes: [(y: CGFloat, c1: CGPoint, c2: CGPoint, end: CGPoint)] = [
        (8.5, CGPoint(x: 12, y: 8), CGPoint(x: 20, y: 9.2), CGPoint(x: 28, y: 8.5)),
        (14, CGPoint(x: 11, y: 13.6), CGPoint(x: 17, y: 14.6), CGPoint(x: 22, y: 14)),
        (19.5, CGPoint(x: 13, y: 19), CGPoint(x: 19, y: 20.2), CGPoint(x: 26, y: 19.5)),
        (25, CGPoint(x: 10, y: 24.7), CGPoint(x: 14, y: 25.4), CGPoint(x: 18, y: 25)),
    ]
    private static let barX: CGFloat = 5
    private static let lateStart: CGFloat = 13

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let k = side / 32
            let line = weight * k
            let style = StrokeStyle(lineWidth: line, lineCap: .round)

            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: Self.barX * k, y: 4 * k))
                    path.addLine(to: CGPoint(x: Self.barX * k, y: 28 * k))
                }
                .stroke(style: style)

                ForEach(Array(Self.strokes.enumerated()), id: \.offset) { index, s in
                    let late = lateJoined.contains(index)
                    let path = Path { path in
                        let startX = late ? Self.lateStart : Self.barX
                        path.move(to: CGPoint(x: startX * k, y: s.y * k))
                        path.addCurve(
                            to: CGPoint(x: s.end.x * k, y: s.end.y * k),
                            control1: CGPoint(x: s.c1.x * k, y: s.c1.y * k),
                            control2: CGPoint(x: s.c2.x * k, y: s.c2.y * k))
                    }

                    switch streams {
                    case .solid:
                        path.stroke(style: style)
                    case .outline:
                        // The stroke's own outline: the shape it would fill,
                        // drawn hollow. Thin enough that at 18 pt the eye
                        // reads "empty tube", not "two lines".
                        path.strokedPath(style)
                            .stroke(lineWidth: max(0.75, line * 0.28))
                    }
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// State, in a word and a colour, at a glance.
struct StatePill: View {
    let label: String
    let colour: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(colour)
                .frame(width: 6, height: 6)
            Text(label)
                .font(Type.body(10.5, .medium))
                .foregroundStyle(colour)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(colour.opacity(0.12)))
    }
}
