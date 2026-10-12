import SwiftUI

/// A photo exactly as it will be saved: rotated, cropped to the largest upright rectangle, then cropped to
/// `crop`. Give it a frame with the final aspect (`Geometry.finalAspect`) and it fills that frame.
struct EditedImage: View {
    let image: CGImage
    var rotation: Double = 0
    var crop: CGRect?

    var body: some View {
        GeometryReader { geo in
            let c = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            // The leveled frame this crop is cut from, at this scale.
            let full = CGSize(width: geo.size.width / max(c.width, 0.001), height: geo.size.height / max(c.height, 0.001))
            let zoom = 1 / Geometry.cropScale(width: full.width, height: full.height, degrees: rotation)
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: full.width, height: full.height)
                .rotationEffect(.degrees(-rotation))
                .scaleEffect(zoom)
                .frame(width: full.width, height: full.height)
                .clipped()
                .offset(x: -c.minX * full.width, y: -c.minY * full.height)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
        }
    }
}

/// Crop aspect choices.
enum CropRatio: String, CaseIterable, Identifiable {
    case original, free, square, fourFive, threeTwo, sixteenNine
    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: return "Original"
        case .free: return "Free"
        case .square: return "1:1"
        case .fourFive: return "4:5"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        }
    }

    /// Whether flipping (⟲) changes anything.
    var flippable: Bool { [.fourFive, .threeTwo, .sixteenNine].contains(self) }

    /// The label as shown: flipped ratios read the other way round (4:5 ↔ 5:4).
    func label(flipped: Bool) -> String {
        guard flipped, flippable else { return label }
        let parts = label.split(separator: ":")
        return "\(parts[1]):\(parts[0])"
    }

    /// Width / height in pixels, exactly as labeled (4:5 is tall, 3:2 and 16:9 are wide); `flipped` swaps it.
    func value(photoAspect aspect: CGFloat, portrait flipped: Bool) -> CGFloat? {
        let base: CGFloat
        switch self {
        case .free: return nil
        case .original: return aspect
        case .square: return 1
        case .fourFive: base = 4.0 / 5
        case .threeTwo: base = 3.0 / 2
        case .sixteenNine: base = 16.0 / 9
        }
        return flipped ? 1 / base : base
    }
}

enum CropMath {
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// The biggest rectangle with normalized ratio `n` (width/height in 0…1 units) centered on `center`.
    static func fit(ratio n: CGFloat, around center: CGPoint) -> CGRect {
        var w: CGFloat = 1, h = 1 / n
        if h > 1 { h = 1; w = n }
        var r = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        r.origin.x = min(max(r.minX, 0), 1 - w)
        r.origin.y = min(max(r.minY, 0), 1 - h)
        return r
    }
}

/// The crop frame: dims outside, thirds inside, corner and edge handles. Drag inside to move it.
/// `rect` is in 0…1 units of the frame it's drawn over; `ratio` (normalized width/height) locks the shape.
/// At rest (no hover, no drag) it shows only the result: the outside is covered with `matte` and the guides fade.
struct CropOverlay: View {
    @Binding var rect: CGRect
    let ratio: CGFloat?
    var matte: [Color] = [.black]

    @State private var start: CGRect?
    @State private var zone: Zone?
    @State private var hovering = false
    @State private var lingering = false

    private var active: Bool { hovering || start != nil || lingering }

    enum Zone { case move, tl, tr, bl, br, top, bottom, left, right }

    var body: some View {
        GeometryReader { geo in
            let s = geo.size
            let r = CGRect(x: rect.minX * s.width, y: rect.minY * s.height, width: rect.width * s.width, height: rect.height * s.height)
            let outside = Path { p in p.addRect(CGRect(origin: .zero, size: s)); p.addRect(r) }
            ZStack(alignment: .topLeading) {
                ZStack { ForEach(matte.indices, id: \.self) { outside.fill(matte[$0], style: FillStyle(eoFill: true)) } }
                    .opacity(active ? 0 : 1)
                outside.fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .opacity(active ? 1 : 0)
                Path { p in
                    for i in 1...2 {
                        let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                        p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                    }
                }
                .stroke(.white.opacity(0.45), lineWidth: 0.5)
                .opacity(active ? 1 : 0)
                Rectangle().stroke(.white.opacity(0.9), lineWidth: 1)
                    .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    .opacity(active ? 1 : 0)
                // Corner brackets
                Path { p in
                    let l: CGFloat = min(18, r.width / 3, r.height / 3)
                    for (c, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                        (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
                        p.move(to: CGPoint(x: c.x + dx * l, y: c.y)); p.addLine(to: c); p.addLine(to: CGPoint(x: c.x, y: c.y + dy * l))
                    }
                }
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))
                .opacity(active ? 1 : 0.35)
            }
            .animation(.easeOut(duration: 0.2), value: active)
            .contentShape(Rectangle())
            #if os(macOS)
            .onContinuousHover { phase in
                if case .active = phase { hovering = true } else { hovering = false }
                guard start == nil else { return }
                if case .active(let p) = phase { CropCursor.set(hit(p, r), dragging: false) } else { NSCursor.arrow.set() }
            }
            #endif
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if start == nil {
                            start = rect; zone = hit(g.startLocation, r)
                            #if os(macOS)
                            CropCursor.set(zone, dragging: true)
                            #endif
                        }
                        guard let base = start, let zone else { return }
                        rect = update(base, zone: zone, dx: g.translation.width / s.width, dy: g.translation.height / s.height)
                    }
                    .onEnded { g in
                        #if os(macOS)
                        CropCursor.set(zone, dragging: false)
                        #else
                        // No hover on touch: keep the guides a moment after lifting the finger, then show the result.
                        lingering = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if start == nil { lingering = false } }
                        #endif
                        start = nil; zone = nil
                    }
            )
        }
    }

    private func hit(_ p: CGPoint, _ r: CGRect) -> Zone? {
        let k: CGFloat = 22
        let nearL = abs(p.x - r.minX) < k, nearR = abs(p.x - r.maxX) < k
        let nearT = abs(p.y - r.minY) < k, nearB = abs(p.y - r.maxY) < k
        if nearL && nearT { return .tl }
        if nearR && nearT { return .tr }
        if nearL && nearB { return .bl }
        if nearR && nearB { return .br }
        let inY = p.y > r.minY && p.y < r.maxY, inX = p.x > r.minX && p.x < r.maxX
        if nearL && inY { return .left }
        if nearR && inY { return .right }
        if nearT && inX { return .top }
        if nearB && inX { return .bottom }
        return r.contains(p) ? .move : nil
    }

    private func update(_ b: CGRect, zone: Zone, dx: CGFloat, dy: CGFloat) -> CGRect {
        let minSide: CGFloat = 0.06
        if zone == .move {
            return CGRect(x: min(max(b.minX + dx, 0), 1 - b.width), y: min(max(b.minY + dy, 0), 1 - b.height),
                          width: b.width, height: b.height)
        }
        var minX = b.minX, maxX = b.maxX, minY = b.minY, maxY = b.maxY
        switch zone {
        case .tl: minX += dx; minY += dy
        case .tr: maxX += dx; minY += dy
        case .bl: minX += dx; maxY += dy
        case .br: maxX += dx; maxY += dy
        case .left: minX += dx
        case .right: maxX += dx
        case .top: minY += dy
        case .bottom: maxY += dy
        case .move: break
        }
        minX = max(0, min(minX, maxX - minSide)); maxX = min(1, max(maxX, minX + minSide))
        minY = max(0, min(minY, maxY - minSide)); maxY = min(1, max(maxY, minY + minSide))
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let n = ratio else { return r }
        // Keep the ratio: the dragged dimension leads; the other follows, anchored at the opposite side.
        let horizontalLead = [.left, .right].contains(zone) || ([.tl, .tr, .bl, .br].contains(zone) && abs(dx) >= abs(dy))
        if horizontalLead {
            var h = r.width / n
            if h > 1 { h = 1; r.size.width = n }
            if [.tl, .tr, .top].contains(zone) { r.origin.y = maxY - h } else if [.left, .right].contains(zone) { r.origin.y = b.midY - h / 2 }
            r.size.height = h
        } else {
            var w = r.height * n
            if w > 1 { w = 1; r.size.height = 1 / n }
            if [.tl, .bl, .left].contains(zone) { r.origin.x = maxX - w } else if [.top, .bottom].contains(zone) { r.origin.x = b.midX - w / 2 }
            r.size.width = w
            if [.tl, .tr].contains(zone) { r.origin.y = maxY - r.height }
        }
        r.origin.x = min(max(r.minX, 0), 1 - r.width)
        r.origin.y = min(max(r.minY, 0), 1 - r.height)
        return r
    }
}

#if os(macOS)
import AppKit

/// Mac pointer for each part of the crop frame: diagonal arrows on corners, ↔ / ↕ on edges, a hand inside.
enum CropCursor {
    static func set(_ zone: CropOverlay.Zone?, dragging: Bool) {
        cursor(zone, dragging: dragging).set()
    }

    private static func cursor(_ zone: CropOverlay.Zone?, dragging: Bool) -> NSCursor {
        switch zone {
        case .move: return dragging ? .closedHand : .openHand
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .tl, .br, .tr, .bl:
            if #available(macOS 15.0, *) {
                let pos: NSCursor.FrameResizePosition = zone == .tl ? .topLeft : zone == .tr ? .topRight : zone == .bl ? .bottomLeft : .bottomRight
                return .frameResize(position: pos, directions: .all)
            }
            return .crosshair
        case nil: return .arrow
        }
    }
}
#endif
