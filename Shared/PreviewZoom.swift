import SwiftUI

/// A zoom request from a menu or the keyboard (Mac View menu, iPad PadCommands).
enum ZoomCommand: Equatable { case zoomIn, zoomOut, fit }

/// Zoom and pan of the preview (Mac) / editor (iPhone, iPad) canvas, from fit (1×) to 8×.
///
/// Zooming doesn't scale the canvas: it makes the photo's frame bigger (and moves it), and every overlay
/// (crop frame, grid, guide, dashed horizon, picker, loupes) is laid out from that frame as before. So gestures
/// keep working in canvas coordinates, lines stay hairline-thin and handles keep their size.
struct PreviewZoom: Equatable {
    /// 1 = the whole photo fits the canvas.
    var scale: CGFloat = 1
    /// Offset of the photo's centre from the canvas centre, in points. Always clamped: the photo never leaves the view.
    var pan: CGSize = .zero
    /// The last layout, set by the canvas: the photo's size at fit and the canvas size.
    var fit: CGSize = .zero
    var area: CGSize = .zero

    static let maxScale: CGFloat = 8
    /// ⌘+ / ⌘− steps.
    static let steps: [CGFloat] = [1, 1.5, 2, 3, 4, 6, 8]

    var isZoomed: Bool { scale > 1.001 }
    var percent: Int { Int((scale * 100).rounded()) }

    /// The photo's rect in a canvas of `area` for a photo that fits at `fit`.
    func frame(fit: CGSize, in area: CGSize) -> CGRect {
        let size = CGSize(width: fit.width * scale, height: fit.height * scale)
        let p = Self.clamp(pan, size: size, area: area)
        return CGRect(x: (area.width - size.width) / 2 + p.width, y: (area.height - size.height) / 2 + p.height,
                      width: size.width, height: size.height)
    }

    /// The part of `frame` that's on screen (where overlays may take clicks and touches).
    static func visible(_ frame: CGRect, in area: CGSize) -> CGRect {
        let v = frame.intersection(CGRect(origin: .zero, size: area))
        return v.isNull ? .zero : v
    }

    static func clamp(_ pan: CGSize, size: CGSize, area: CGSize) -> CGSize {
        let mx = max(0, (size.width - area.width) / 2), my = max(0, (size.height - area.height) / 2)
        return CGSize(width: min(max(pan.width, -mx), mx), height: min(max(pan.height, -my), my))
    }

    private func clamped(_ p: CGSize, scale s: CGFloat) -> CGSize {
        Self.clamp(p, size: CGSize(width: fit.width * s, height: fit.height * s), area: area)
    }

    private var center: CGPoint { CGPoint(x: area.width / 2, y: area.height / 2) }

    /// The canvas reports its layout (on appear, resize, crop mode on/off): the scale stays, the pan is re-clamped.
    mutating func layout(fit: CGSize, area: CGSize) {
        guard fit != self.fit || area != self.area else { return }
        self.fit = fit; self.area = area
        pan = clamped(pan, scale: scale)
    }

    /// Zoom to `s`, keeping the photo point under `anchor` (canvas coordinates; nil = the centre) where it is.
    mutating func zoom(to s: CGFloat, at anchor: CGPoint? = nil) {
        let s1 = min(max(s, 1), Self.maxScale)
        guard s1 > 1.001 else { reset(); return }
        let a = anchor ?? center
        let d = CGSize(width: a.x - center.x, height: a.y - center.y)
        let k = s1 / scale
        pan = clamped(CGSize(width: d.width - (d.width - pan.width) * k, height: d.height - (d.height - pan.height) * k), scale: s1)
        scale = s1
    }

    /// Pinch: from the state when two fingers came down (`start`, `startPoint`), the fingers' scale and centroid now.
    /// The photo point that was under the fingers stays under them, so a pinch also pans.
    mutating func pinch(from start: PreviewZoom, startPoint: CGPoint, scale g: CGFloat, point: CGPoint) {
        let s1 = min(max(start.scale * g, 1), Self.maxScale)
        let u = CGSize(width: (startPoint.x - center.x - start.pan.width) / start.scale,
                       height: (startPoint.y - center.y - start.pan.height) / start.scale)
        scale = s1
        pan = clamped(CGSize(width: point.x - center.x - u.width * s1, height: point.y - center.y - u.height * s1), scale: s1)
        if s1 <= 1.001 { scale = 1; pan = .zero }
    }

    mutating func pan(by d: CGSize) { pan = clamped(CGSize(width: pan.width + d.width, height: pan.height + d.height), scale: scale) }
    mutating func pan(to p: CGSize) { pan = clamped(p, scale: scale) }

    /// Put this spot of the photo (0…1 of its width and height) in the middle of the canvas, as far as the clamp allows.
    mutating func center(on u: CGPoint) {
        pan(to: CGSize(width: fit.width * scale * (0.5 - u.x), height: fit.height * scale * (0.5 - u.y)))
    }

    mutating func reset() { scale = 1; pan = .zero }

    /// Double-click / double-tap: fit ⇄ 2× at the point.
    mutating func toggle(at p: CGPoint?) { if isZoomed { reset() } else { zoom(to: 2, at: p) } }

    mutating func step(_ dir: Int, at anchor: CGPoint? = nil) {
        let next = dir > 0 ? Self.steps.first { $0 > scale + 0.01 } ?? Self.maxScale
                           : Self.steps.last { $0 < scale - 0.01 } ?? 1
        zoom(to: next, at: anchor)
    }

    mutating func apply(_ c: ZoomCommand) {
        switch c {
        case .zoomIn: step(1)
        case .zoomOut: step(-1)
        case .fit: reset()
        }
    }

    /// The same spot of the photo in a new frame (the two-point picker's ends follow a zoom).
    static func remap(_ p: CGPoint, from a: CGRect, to b: CGRect) -> CGPoint {
        guard a.width > 0, a.height > 0 else { return p }
        return CGPoint(x: b.minX + (p.x - a.minX) / a.width * b.width, y: b.minY + (p.y - a.minY) / a.height * b.height)
    }
}

/// "200% · Fit", bottom-right over the photo while zoomed; Fit goes back to the whole photo.
struct ZoomPill: View {
    let zoom: PreviewZoom
    let fit: () -> Void

    var body: some View {
        if zoom.isZoomed {
            HStack(spacing: 6) {
                Text("\(zoom.percent)%").monospacedDigit()
                Text("·").opacity(0.5)
                Button(action: fit) { Text("Fit").fontWeight(.semibold).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    .help("Fit the whole photo (⌘0)")
                    #else
                    .accessibilityLabel("Fit the whole photo")
                    #endif
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(10)
            .transition(.opacity)
        }
    }
}

/// While zoomed in: the whole photo, small, with the part on screen outlined and the rest dimmed.
/// Press or drag it to move around the photo.
struct ZoomNavigator<Photo: View>: View {
    let zoom: PreviewZoom
    /// The photo's frame in the canvas (bigger than the canvas while zoomed in).
    let frame: CGRect
    let area: CGSize
    /// Off in the tools that use the drag themselves (crop, level tool, Fixes): it fades and lets the drag through,
    /// so a handle or a point underneath can still be reached.
    var movable = true
    /// Which corner on the left, top or bottom. Put the view in the canvas's overlay with the matching alignment.
    var edge: VerticalEdge = .top
    /// The spot of the photo (0…1) to bring to the middle of the canvas.
    let move: (CGPoint) -> Void
    @ViewBuilder let photo: () -> Photo

    /// How far the press was from the outline's centre, so grabbing the outline doesn't make it jump.
    @State private var grab: CGSize?

    /// The long side follows the canvas, within limits (a phone's width gives about 96 pt).
    private var size: CGSize {
        let long = min(max(min(area.width, area.height) * 0.24, 84), 150)
        return frame.width >= frame.height
            ? CGSize(width: long, height: long * frame.height / frame.width)
            : CGSize(width: long * frame.width / frame.height, height: long)
    }

    /// The part on screen, in the navigator's coordinates.
    private var outline: CGRect {
        let v = PreviewZoom.visible(frame, in: area)
        return CGRect(x: (v.minX - frame.minX) / frame.width * size.width, y: (v.minY - frame.minY) / frame.height * size.height,
                      width: v.width / frame.width * size.width, height: v.height / frame.height * size.height)
    }

    var body: some View {
        if zoom.isZoomed, frame.width > 0, frame.height > 0 {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            let box = outline
            let shown = PreviewZoom.visible(frame, in: area)
            photo()
                .frame(width: size.width, height: size.height)
                .overlay {
                    Path { p in p.addRect(CGRect(origin: .zero, size: size)); p.addRect(box) }
                        .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                    Path(box).stroke(.white, lineWidth: 1.25)
                }
                .clipShape(shape)
                .overlay(shape.stroke(.white.opacity(0.3), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
                .contentShape(shape)
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let offset = grab ?? (box.contains(g.startLocation)
                        ? CGSize(width: box.midX - g.startLocation.x, height: box.midY - g.startLocation.y) : .zero)
                    grab = offset
                    move(CGPoint(x: (g.location.x + offset.width) / size.width, y: (g.location.y + offset.height) / size.height))
                }.onEnded { _ in grab = nil })
                .allowsHitTesting(movable)
                .opacity(movable ? 1 : 0.65)
                .padding(10)
                // Over the photo, not the empty canvas around it (at a low zoom it may not fill the canvas yet).
                .padding(.leading, shown.minX)
                .padding(edge == .top ? .top : .bottom, edge == .top ? shown.minY : area.height - shown.maxY)
                .transition(.opacity)
                .accessibilityElement()
                .accessibilityLabel("The part of the photo on screen")
        }
    }
}

extension LinePick {
    /// Keep the picked ends on the same spot of the photo when its frame moves (zoom, pan, resize).
    mutating func remap(from a: CGRect, to b: CGRect) {
        guard a != b, a.width > 0, b.width > 0 else { return }
        points = points.map { PreviewZoom.remap($0, from: a, to: b) }
        hover = hover.map { PreviewZoom.remap($0, from: a, to: b) }
        start = start.map { PreviewZoom.remap($0, from: a, to: b) }
        origin = origin.map { PreviewZoom.remap($0, from: a, to: b) }
    }
}
