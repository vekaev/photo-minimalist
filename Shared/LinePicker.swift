import SwiftUI

/// Picking two points on the horizon, Apple Notes–style: press to place a point (a magnifier follows while you
/// hold), place the second, then drag either end to fine-tune with its magnifier. Nothing rotates until you
/// confirm, so the points stay exactly on what you aimed at. Shared by the Mac and iPhone apps.
struct LinePick: Equatable {
    var points: [CGPoint] = []
    /// The point being dragged right now.
    var active: Int?
    /// Where the press started, to tell a tap or adjustment from a swipe (iPhone).
    var start: CGPoint?
    /// True when this press created a new point (so a swipe can take it back).
    var created = false
    /// Where an existing end was when it was grabbed: re-dragging an end moves it at `fine` speed, for precision.
    var origin: CGPoint?
    /// The end last placed or touched; arrow keys nudge it (Mac).
    var focus: Int?
    /// The pointer while the second end is being aimed (Mac hover): a rubber-band line follows it.
    var hover: CGPoint?

    static let grab: CGFloat = 22
    static let fine: CGFloat = 0.25

    var isEmpty: Bool { points.isEmpty }
    var isComplete: Bool { points.count == 2 }

    /// Press down (or the first movement of a drag). New points only count on the photo itself.
    mutating func press(at p: CGPoint, within photo: CGRect = .infinite) {
        start = p
        let nearest = points.indices.min(by: { dist(points[$0], p) < dist(points[$1], p) })
        let grabbing = nearest.map { dist(points[$0], p) <= Self.grab } ?? false
        guard grabbing || photo.contains(p) else { active = nil; created = false; return }
        if let i = points.indices.min(by: { dist(points[$0], p) < dist(points[$1], p) }), dist(points[i], p) <= Self.grab {
            active = i; created = false; origin = points[i]   // grab an existing end: fine-tune it
        } else if points.count < 2 {
            points.append(p); active = points.count - 1; created = true
        } else {
            points = [p]; active = 0; created = true          // a third press starts over
        }
        focus = active; hover = nil
    }

    mutating func move(to p: CGPoint, within photo: CGRect = .infinite) {
        guard let i = active, points.indices.contains(i) else { return }
        var target = p
        if !created, let o = origin, let s = start {
            target = CGPoint(x: o.x + (p.x - s.x) * Self.fine, y: o.y + (p.y - s.y) * Self.fine)
        }
        points[i] = clamp(target, photo)
    }

    /// Move the focused end by a few points (arrow keys).
    mutating func nudge(dx: CGFloat, dy: CGFloat, within photo: CGRect = .infinite) {
        guard let i = focus ?? points.indices.last, points.indices.contains(i) else { return }
        points[i] = clamp(CGPoint(x: points[i].x + dx, y: points[i].y + dy), photo)
        focus = i
    }

    mutating func release() { active = nil; start = nil; created = false; origin = nil }

    private func clamp(_ p: CGPoint, _ photo: CGRect) -> CGPoint {
        photo.isInfinite ? p : CGPoint(x: min(max(p.x, photo.minX), photo.maxX), y: min(max(p.y, photo.minY), photo.maxY))
    }

    /// Undo the point this press created (the press turned out to be a swipe).
    mutating func cancelPress() {
        if created, let i = active, points.indices.contains(i) { points.remove(at: i) }
        release()
    }

    mutating func clear() { self = LinePick() }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

/// The thin, see-through line and small ring handles.
struct LinePickOverlay: View {
    let pick: LinePick

    var body: some View {
        ZStack(alignment: .topLeading) {
            if pick.points.count == 1, pick.active == nil, let h = pick.hover {
                // Rubber band from the first end to the pointer, with the tilt it would fix.
                let line = Path { p in p.move(to: pick.points[0]); p.addLine(to: h) }
                line.stroke(.black.opacity(0.2), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                line.stroke(.white.opacity(0.65), style: StrokeStyle(lineWidth: 0.75, dash: [5, 4]))
                if hypot(h.x - pick.points[0].x, h.y - pick.points[0].y) > 40 {
                    Text(Geometry.format(-Geometry.lineTilt(from: pick.points[0], to: h)))
                        .font(.caption2.weight(.medium)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .position(x: h.x, y: h.y + 22)
                }
            }
            if pick.points.count == 2 {
                let line = Path { p in p.move(to: pick.points[0]); p.addLine(to: pick.points[1]) }
                line.stroke(.black.opacity(0.25), lineWidth: 2)
                line.stroke(.white.opacity(0.7), lineWidth: 0.75)
            }
            ForEach(Array(pick.points.enumerated()), id: \.offset) { i, pt in
                ZStack {
                    Circle().stroke(.black.opacity(0.3), lineWidth: 2.5)
                    Circle().stroke(.white.opacity(0.9), lineWidth: 1)
                    Circle().fill(.white.opacity(0.9)).frame(width: 2.5, height: 2.5)
                }
                .frame(width: pick.active == i ? 16 : 11, height: pick.active == i ? 16 : 11)
                .position(pt)
                .animation(.easeOut(duration: 0.12), value: pick.active)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A round magnifier: shows `content` (laid out in a `canvas`-sized frame) zoomed around `focus`, with a crosshair.
struct PointLoupe<Content: View>: View {
    let canvas: CGSize
    let focus: CGPoint
    var zoom: CGFloat = 4
    var diameter: CGFloat = 120
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: canvas.width, height: canvas.height)
            .scaleEffect(zoom, anchor: UnitPoint(x: focus.x / max(canvas.width, 1), y: focus.y / max(canvas.height, 1)))
            .offset(x: diameter / 2 - focus.x, y: diameter / 2 - focus.y)
            .frame(width: diameter, height: diameter, alignment: .topLeading)
            .clipped()
            .overlay {
                Canvas { ctx, s in
                    var cross = Path()
                    let c = CGPoint(x: s.width / 2, y: s.height / 2), gap: CGFloat = 5
                    cross.move(to: CGPoint(x: 0, y: c.y)); cross.addLine(to: CGPoint(x: c.x - gap, y: c.y))
                    cross.move(to: CGPoint(x: c.x + gap, y: c.y)); cross.addLine(to: CGPoint(x: s.width, y: c.y))
                    cross.move(to: CGPoint(x: c.x, y: 0)); cross.addLine(to: CGPoint(x: c.x, y: c.y - gap))
                    cross.move(to: CGPoint(x: c.x, y: c.y + gap)); cross.addLine(to: CGPoint(x: c.x, y: s.height))
                    ctx.stroke(cross, with: .color(.black.opacity(0.35)), lineWidth: 2)
                    ctx.stroke(cross, with: .color(.white.opacity(0.85)), lineWidth: 0.75)
                }
            }
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .allowsHitTesting(false)
    }

    /// Where to put a magnifier for a point: above it (clear of a finger or cursor), or below near the top edge.
    static func position(for p: CGPoint, in area: CGSize, diameter: CGFloat = 120, lift: CGFloat = 90) -> CGPoint {
        let r = diameter / 2
        var y = p.y - lift - r
        if y - r < 4 { y = p.y + lift + r }
        let x = min(max(p.x, r + 4), area.width - r - 4)
        return CGPoint(x: x, y: min(max(y, r + 4), area.height - r - 4))
    }
}
