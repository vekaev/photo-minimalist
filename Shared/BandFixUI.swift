import SwiftUI

// Pieces of the Fixes panel (Mac) and sheet (iPhone) that read the same on both: the per-side status lines and the
// brightness profile chart.

extension BandAnalysis {
    /// "band 25.7% darker — correcting" / "3.1%, below threshold — left alone" / "no clean area to measure".
    func statusText(_ side: BandSide) -> String {
        let a = self.side(side)
        let strength = settings.strength(side)
        switch a.status {
        case .noCleanArea:
            return "no clean area to measure"
        case .correcting(let d):
            let base = String(format: "band %.1f%% darker", d * 100)
            return base + (strength > 0 ? " — correcting" : " — strength 0, off")
        case .belowThreshold(let d):
            let base = String(format: "%.1f%%, below threshold", d * 100)
            return base + (settings.force && strength > 0 ? " — corrected anyway" : " — left alone")
        }
    }
}

/// "Left: band 25.7% darker — correcting", one line per side.
struct BandStatusLines: View {
    let analysis: BandAnalysis?
    var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(BandSide.allCases, id: \.self) { side in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(side == .left ? "Left" : "Right").fontWeight(.medium)
                        .frame(width: 38, alignment: .leading)
                    if let analysis {
                        Text(analysis.statusText(side))
                            .foregroundStyle(analysis.side(side).isApplied(analysis.settings) ? .primary : .secondary)
                    } else {
                        Text(loading ? "measuring…" : "—").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.callout)
        .monospacedDigit()
    }
}

/// Brightness across the frame (log luminance, measured rows): before in a thin secondary line, after in the primary
/// ink, dashed lines at the zone boundaries. Flat after = no band left.
struct BandProfileChart: View {
    let analysis: BandAnalysis?

    var body: some View {
        Canvas { ctx, size in
            guard let a = analysis, a.profileBefore.count > 1, a.profileAfter.count == a.profileBefore.count else { return }
            let before = a.profileBefore, after = a.profileAfter
            let all = before + after
            guard let lo = all.min(), let hi = all.max() else { return }
            let pad = (hi - lo) * 0.1 + 1e-3
            let n = before.count
            func x(_ i: Int) -> CGFloat { CGFloat(i) / CGFloat(n - 1) * size.width }
            func y(_ v: Double) -> CGFloat { size.height - 4 - CGFloat((v - lo + pad) / (hi - lo + 2 * pad)) * (size.height - 8) }
            var zones = Path()
            for z in [a.settings.zoneLeft, 1 - a.settings.zoneRight] {
                zones.move(to: CGPoint(x: z * size.width, y: 0))
                zones.addLine(to: CGPoint(x: z * size.width, y: size.height))
            }
            ctx.stroke(zones, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
            func line(_ v: [Double]) -> Path {
                var p = Path()
                for (i, value) in v.enumerated() {
                    let pt = CGPoint(x: x(i), y: y(value))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                return p
            }
            ctx.stroke(line(before), with: .color(.secondary.opacity(0.7)), lineWidth: 1)
            ctx.stroke(line(after), with: .color(.primary), lineWidth: 1.5)
        }
        .frame(height: 96)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 12) {
                legend("before", .secondary.opacity(0.7), 1)
                legend("after", .primary, 1.5)
                Text("measured rows").foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .offset(y: 18)
        }
        .padding(.bottom, 18)
        .accessibilityLabel("Brightness across the frame, before and after")
    }

    private func legend(_ text: String, _ color: Color, _ width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 12, height: width + 0.5)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// How the panel shows the photo.
enum BandFixView: String, CaseIterable, Identifiable {
    case before, after, split
    var id: String { rawValue }
    var label: String { self == .before ? "Before" : self == .after ? "After" : "Split" }
}
