import AppKit
import SwiftUI

/// Monochrome, Notion-like palette that follows the system light / dark appearance.
enum Theme {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    private static func gray(_ w: CGFloat) -> NSColor { NSColor(white: w, alpha: 1) }

    static let ground = dynamic(gray(1.0), gray(0.098))      // page
    static let panel = dynamic(NSColor(red: 0.969, green: 0.969, blue: 0.961, alpha: 1), gray(0.125)) // sidebar
    static let raised = dynamic(gray(0.925), gray(0.18))     // selected row, keycaps
    static let line = Color.primary.opacity(0.09)            // hairlines
    static let accent = Color.primary
    static let keep = Color.primary
    /// For marks drawn on top of photos.
    static let onPhoto = Color.white

    static func color(for status: Status) -> Color {
        switch status {
        case .level, .keep: return .primary
        case .needsReview: return .primary.opacity(0.7)
        default: return .secondary
        }
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
                    ctx.stroke(p, with: .color(.primary.opacity(isWhole ? 0.55 : 0.22)), lineWidth: isWhole ? 1 : 0.5)
                    if isFive || (isWhole && pointsPerDegree >= 24) {
                        let label = Text(isFive ? "\(tenths / 10)°" : "\(tenths / 10)")
                            .font(.system(size: isFive ? 11 : 9, design: .monospaced))
                            .foregroundStyle(.primary.opacity(isFive ? 0.7 : 0.4))
                        ctx.draw(label, at: CGPoint(x: x, y: size.height - h - 8))
                    }
                }
                t += 1
            }
            var marker = Path()
            marker.move(to: CGPoint(x: mid, y: 4)); marker.addLine(to: CGPoint(x: mid, y: size.height))
            ctx.stroke(marker, with: .color(.primary), lineWidth: 1.5)
        }
        .frame(height: 44)
        .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing))
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
