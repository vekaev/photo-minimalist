import SwiftUI

/// The start page's mark, one quiet glyph: an ink disc (the lens, or a sun) resting on a dead-level horizon. The
/// line runs through the disc as a paper gap, so the horizon is the one thing that stays straight across it.
/// Draws in one ink colour; the gap is truly transparent, so it works on any paper, light or dark.
struct StartArt: View {
    /// The Mac passes pure black / white (its `.primary` is a softer 85 % black).
    var ink: Color = .primary

    var body: some View {
        Canvas { ctx, size in
            // Laid out on a 120 × 56 sketch, scaled to fit and centred.
            let s = min(size.width / 120, size.height / 56)
            ctx.translateBy(x: (size.width - 120 * s) / 2, y: (size.height - 56 * s) / 2)
            ctx.scaleBy(x: s, y: s)
            let c = CGPoint(x: 60, y: 28), r: CGFloat = 26, line: CGFloat = 3.2
            ctx.drawLayer { ctx in
                var horizon = Path()
                horizon.move(to: CGPoint(x: line / 2, y: c.y))
                horizon.addLine(to: CGPoint(x: 120 - line / 2, y: c.y))
                ctx.stroke(horizon, with: .color(ink), style: StrokeStyle(lineWidth: line, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(ink))
                ctx.blendMode = .destinationOut
                ctx.fill(Path(CGRect(x: c.x - r, y: c.y - line / 2, width: 2 * r, height: line)), with: .color(.black))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Stoic-like start page type: big, bold, lowercase, ending in a period.
struct InkHeadline: View {
    let text: String
    var size: CGFloat = 44

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold))
            .tracking(-size * 0.025)
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The black pill gives a little when pressed.
struct InkPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
