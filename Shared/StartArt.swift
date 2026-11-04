import SwiftUI

/// The start page's ink drawing: a chunky camera sitting on a hand-drawn horizon, a level vial on its top with the
/// bubble dead centre, a level line across the lens, and a sun peeking out behind. Bold ink on paper: it draws in
/// the foreground colour, and every cutout is truly transparent, so it works on any background, light or dark.
struct StartArt: View {
    /// The Mac passes pure black / white (its `.primary` is a softer 85 % black).
    var ink: Color = .primary

    var body: some View {
        Canvas { ctx, size in
            // Laid out on a 220 × 150 sketch, scaled to fit and centred.
            let s = min(size.width / 220, size.height / 150)
            ctx.translateBy(x: (size.width - 220 * s) / 2, y: (size.height - 150 * s) / 2)
            ctx.scaleBy(x: s, y: s)
            let ink = GraphicsContext.Shading.color(self.ink)
            let round = StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)

            ctx.drawLayer { ctx in
                // The sun, behind the camera, with three short ink rays.
                ctx.fill(Path(ellipseIn: CGRect(x: 146, y: 22, width: 44, height: 44)), with: ink)
                var rays = Path()
                for degrees in [-78.0, -40.0, -2.0] {
                    let a = degrees * .pi / 180, c = CGPoint(x: 168, y: 44)
                    rays.move(to: CGPoint(x: c.x + 29 * cos(a), y: c.y + 29 * sin(a)))
                    rays.addLine(to: CGPoint(x: c.x + 37 * cos(a), y: c.y + 37 * sin(a)))
                }
                ctx.stroke(rays, with: ink, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))

                // The camera: body + top hump in one shape, with a ring of paper around it where it covers the sun.
                var camera = Path(roundedRect: CGRect(x: 54, y: 62, width: 108, height: 58), cornerRadius: 15, style: .continuous)
                camera.addPath(Path(roundedRect: CGRect(x: 86, y: 47, width: 44, height: 20), cornerRadius: 7, style: .continuous))
                camera.addPath(Path(roundedRect: CGRect(x: 136, y: 54, width: 15, height: 12), cornerRadius: 3.5, style: .continuous))
                ctx.blendMode = .destinationOut
                ctx.stroke(camera, with: .color(.black), style: StrokeStyle(lineWidth: 9, lineJoin: .round))
                ctx.blendMode = .normal
                ctx.fill(camera, with: ink)

                // Cut into the camera: the vial (bubble centred), the viewfinder window, the lens ring, a glint.
                ctx.blendMode = .destinationOut
                let cut = GraphicsContext.Shading.color(.black)
                ctx.fill(Path(roundedRect: CGRect(x: 92, y: 52.5, width: 32, height: 9), cornerRadius: 4.5), with: cut)
                ctx.fill(Path(roundedRect: CGRect(x: 66, y: 71, width: 15, height: 7), cornerRadius: 2.5), with: cut)
                ctx.fill(Path(ellipseIn: CGRect(x: 108 - 24, y: 92 - 24, width: 48, height: 48)), with: cut)
                ctx.blendMode = .normal
                ctx.fill(Path(ellipseIn: CGRect(x: 108 - 2.8, y: 57 - 2.8, width: 5.6, height: 5.6)), with: ink)
                ctx.fill(Path(ellipseIn: CGRect(x: 108 - 18.5, y: 92 - 18.5, width: 37, height: 37)), with: ink)
                ctx.blendMode = .destinationOut
                // In the lens: a dead-level horizon, and a small glint above it.
                ctx.fill(Path(roundedRect: CGRect(x: 93, y: 91, width: 30, height: 2.8), cornerRadius: 1.4), with: cut)
                ctx.fill(Path(ellipseIn: CGRect(x: 97.5, y: 80, width: 5, height: 5)), with: cut)
                ctx.blendMode = .normal

                // Last, so the paper ring round the camera doesn't cut it. The horizon: one wobbly brush line and two short flicks under it.
                ctx.stroke(Self.wobbly(from: 6, to: 214, y: 124, wobble: [0, -1.1, 0.6, -0.4, 1.0, -0.8, 0.3, 0]),
                           with: ink, style: StrokeStyle(lineWidth: 3.6, lineCap: .round, lineJoin: .round))
                ctx.stroke(Self.wobbly(from: 20, to: 44, y: 134, wobble: [0, 0.6, 0]), with: ink, style: round)
                ctx.stroke(Self.wobbly(from: 172, to: 204, y: 135, wobble: [0, -0.5, 0.4, 0]), with: ink, style: round)
            }
        }
        .accessibilityHidden(true)
    }

    /// A brush line from `from` to `to` that wanders a little around `y` (one offset per evenly spaced point).
    private static func wobbly(from x0: CGFloat, to x1: CGFloat, y: CGFloat, wobble: [CGFloat]) -> Path {
        let points = wobble.enumerated().map { i, dy in
            CGPoint(x: x0 + (x1 - x0) * CGFloat(i) / CGFloat(wobble.count - 1), y: y + dy)
        }
        var path = Path()
        path.move(to: points[0])
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: mid, control: points[i - 1])
        }
        path.addLine(to: points[points.count - 1])
        return path
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
