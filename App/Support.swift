import AppKit
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.95, green: 0.66, blue: 0.23)
    static let keep = Color(red: 0.71, green: 0.54, blue: 0.88)
    static let ground = Color(red: 0.07, green: 0.075, blue: 0.08)
    static let panel = Color(red: 0.10, green: 0.11, blue: 0.12)
    static let raised = Color(red: 0.14, green: 0.15, blue: 0.16)
    static let line = Color(red: 0.18, green: 0.20, blue: 0.22)

    static func color(for status: Status) -> Color {
        switch status {
        case .needsReview: return accent
        case .level: return Color(red: 0.49, green: 0.77, blue: 0.60)
        case .keep: return keep
        case .alreadyLevel: return Color(white: 0.45)
        case .noTilt: return Color(red: 0.25, green: 0.50, blue: 0.85)
        case .pending: return Color(white: 0.3)
        }
    }
}

/// Downscaled, orientation-corrected images, loaded off the main thread and cached by size.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, CGImage>()

    init() { cache.countLimit = 600 }

    func image(for url: URL, maxPixel: Int) async -> CGImage? {
        let key = "\(maxPixel)|\(url.path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            ImageLoader.thumbnail(url, maxPixel: maxPixel)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

struct Keycap: View {
    let key: String
    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .fixedSize()
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
    }
}

enum GridMode: String, CaseIterable, Identifiable {
    case off, thirds, twelve, twentyFour, fine
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .thirds: return "Thirds"
        case .twelve: return "12"
        case .twentyFour: return "24"
        case .fine: return "Fine"
        }
    }
}

/// Lines drawn over a photo. Each line is a dark stroke under a light one, so it stays visible on bright sky and dark water.
/// "Fine" draws a horizontal line every 8 pt with a stronger one every 40 pt.
struct GridOverlay: View {
    let mode: GridMode
    let horizontalOnly: Bool

    var body: some View {
        Canvas { ctx, size in
            var minor = Path(), major = Path()
            func hLine(_ p: inout Path, _ y: CGFloat) { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) }
            func vLine(_ p: inout Path, _ x: CGFloat) { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) }
            switch mode {
            case .off:
                return
            case .fine:
                // Lines start from the middle so one always runs through the center.
                let step: CGFloat = 8
                let mid = size.height / 2
                var k = 0
                while CGFloat(k) * step <= mid {
                    for y in [mid - CGFloat(k) * step, mid + CGFloat(k) * step] where y > 0 && y < size.height {
                        if k % 5 == 0 { hLine(&major, y) } else { hLine(&minor, y) }
                    }
                    k += 1
                }
                if !horizontalOnly {
                    let cx = size.width / 2
                    var j = 0
                    while CGFloat(j) * 40 <= cx {
                        for x in [cx - CGFloat(j) * 40, cx + CGFloat(j) * 40] where x > 0 && x < size.width { vLine(&minor, x) }
                        j += 1
                    }
                }
            default:
                let n = mode == .thirds ? 3 : mode == .twelve ? 12 : 24
                for i in 1..<n {
                    hLine(&major, size.height * CGFloat(i) / CGFloat(n))
                    if !horizontalOnly { vLine(&major, size.width * CGFloat(i) / CGFloat(n)) }
                }
            }
            ctx.stroke(minor, with: .color(.black.opacity(0.22)), lineWidth: 1.5)
            ctx.stroke(minor, with: .color(.white.opacity(0.30)), lineWidth: 0.5)
            ctx.stroke(major, with: .color(.black.opacity(0.35)), lineWidth: 2)
            ctx.stroke(major, with: .color(.white.opacity(0.55)), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
    }
}

/// Rotation ruler like the one in Photos, but finer: drag sideways to rotate; hold Option for 10× precision.
struct StraightenRuler: View {
    let value: Double
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void
    @State private var start: Double?

    private let pointsPerDegree: CGFloat = 28

    var body: some View {
        Canvas { ctx, size in
            let mid = size.width / 2
            let span = Double(mid / pointsPerDegree) + 1
            var t = (value - span).rounded(.down)
            while t <= value + span {
                for sub in 0..<10 {
                    let deg = t + Double(sub) / 10
                    guard deg >= -45, deg <= 45 else { continue }
                    let x = mid + CGFloat(deg - value) * pointsPerDegree
                    let tenths = Int((deg * 10).rounded())
                    let isWhole = tenths % 10 == 0, isFive = tenths % 50 == 0, isHalf = tenths % 5 == 0
                    let h: CGFloat = isFive ? 22 : isWhole ? 15 : isHalf ? 10 : 5
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: size.height - h)); p.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(p, with: .color(.white.opacity(isWhole ? 0.7 : 0.3)), lineWidth: isWhole ? 1 : 0.5)
                    if isFive || (isWhole && pointsPerDegree >= 24) {
                        let label = Text(isFive ? "\(tenths / 10)°" : "\(tenths / 10)")
                            .font(.system(size: isFive ? 11 : 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(isFive ? 0.8 : 0.45))
                        ctx.draw(label, at: CGPoint(x: x, y: size.height - h - 8))
                    }
                }
                t += 1
            }
            var marker = Path()
            marker.move(to: CGPoint(x: mid, y: 4)); marker.addLine(to: CGPoint(x: mid, y: size.height))
            ctx.stroke(marker, with: .color(Theme.accent), lineWidth: 2)
        }
        .frame(height: 52)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topLeading) {
            Text("Drag to rotate · hold ⌥ for fine").font(.caption2).foregroundStyle(.secondary).padding(6)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let base = start ?? value
                    if start == nil { start = value }
                    let fine = NSEvent.modifierFlags.contains(.option) ? 0.1 : 1
                    let next = base - Double(g.translation.width / pointsPerDegree) * fine
                    onChange(min(max((next * 100).rounded() / 100, -45), 45))
                }
                .onEnded { _ in
                    start = nil
                    onCommit(value)
                }
        )
        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        .help("Drag left or right to rotate. Hold Option for 0.01° precision.")
    }
}
