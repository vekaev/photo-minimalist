import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The five light sliders (Exposure, Brightness, Contrast, Highlights, Shadows), the same on the Mac's Adjust bar and
/// the iPhone / iPad light panel. Each shows its value; double-click (Mac) / double-tap the name or value to put it
/// back to 0 (Mac: double-clicking the slider works too). Values near 0 snap to 0 (a haptic tick on iPhone).
/// `onChange` gets every value while a slider moves (live preview); `onCommit` once it's let go, or after a reset
/// (with the new value), which is when the photo's light is stored as one undo step.
struct LightSliders: View {
    let value: LightAdjust
    let onChange: (LightAdjust) -> Void
    let onCommit: (LightAdjust) -> Void
    /// Narrowest a column gets before the sliders wrap onto more rows.
    var minColumn: CGFloat = 150

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minColumn), spacing: 18, alignment: .top)], alignment: .leading, spacing: 10) {
            ForEach(LightAdjust.Control.allCases) { c in
                LightSliderRow(control: c, value: value, onChange: onChange, onCommit: onCommit)
            }
        }
    }
}

private struct LightSliderRow: View {
    let control: LightAdjust.Control
    let value: LightAdjust
    let onChange: (LightAdjust) -> Void
    let onCommit: (LightAdjust) -> Void
    /// The value while this slider is held, so the commit uses exactly what's under the finger.
    @State private var held: LightAdjust?

    private var v: Double { value[control] }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(control.title)
                Spacer(minLength: 4)
                Text(control.format(v)).monospacedDigit()
                    .foregroundStyle(abs(v) < 0.005 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }
            .font(.caption)
            .lineLimit(1)
            .contentShape(Rectangle())
            .modifier(ResetOnDoubleClick(reset: reset))
            .help("Double-click to reset")
            slider
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(control.title)
        .accessibilityValue(control.format(v))
        .accessibilityAdjustableAction { dir in
            var a = value
            let step = (control.range.upperBound - control.range.lowerBound) / 40
            a[control] = min(max(v + (dir == .increment ? step : -step), control.range.lowerBound), control.range.upperBound)
            onCommit(a)
        }
    }

    private var slider: some View {
        FineDial(value: v, control: control,
                 onChange: { new in
                     var a = held ?? value
                     a[control] = new
                     held = a
                     onChange(a)
                 },
                 onCommit: { new in
                     var a = held ?? value
                     a[control] = snapped(new)
                     held = nil
                     onCommit(a)
                 },
                 onReset: reset)
    }

    /// Within half a fine tick of 0 counts as 0 when let go, so the middle is easy to hit.
    private func snapped(_ x: Double) -> Double { abs(x) < FineDial.minor(control) / 2 ? 0 : x }

    private func reset() {
        guard abs(v) >= 0.005 else { return }
        var a = value
        a[control] = 0
        held = nil
        onCommit(a)
    }
}

/// Double-click (Mac: one tap gesture reading the click count, so single clicks aren't delayed) / double-tap.
private struct ResetOnDoubleClick: ViewModifier {
    let reset: () -> Void
    func body(content: Content) -> some View {
        #if os(macOS)
        content.onTapGesture { if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { reset() } }
        #else
        content.onTapGesture(count: 2) { reset() }
        #endif
    }
}

/// A tick ruler like the level ruler, for one light control: the value sits under the centre marker; drag left or
/// right to scrub it (Mac: ⌥ for 10× finer), double-click (double-tap) to reset. Fine ticks every 0.05 EV
/// (Exposure) or 2 (the others), labelled every 0.5 EV / 10. Values are kept to 0.01 EV / 0.5.
struct FineDial: View {
    let value: Double
    let control: LightAdjust.Control
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void
    let onReset: () -> Void
    @State private var start: Double?

    static func minor(_ c: LightAdjust.Control) -> Double { c == .exposure ? 0.05 : 0.02 }
    private var minor: Double { Self.minor(control) }
    /// Every n-th fine tick is long and labelled.
    private let major = 10
    private let pointsPerMinor: CGFloat = 9

    var body: some View {
        Canvas { ctx, size in
            let mid = size.width / 2
            let range = control.range
            let reach = Int((mid / pointsPerMinor).rounded(.up)) + 1
            let centre = Int((value / minor).rounded())
            for i in (centre - reach)...(centre + reach) {
                let v = Double(i) * minor
                guard v >= range.lowerBound - 1e-9, v <= range.upperBound + 1e-9 else { continue }
                let x = mid + CGFloat((v - value) / minor) * pointsPerMinor
                let isMajor = i % major == 0, isHalf = i % (major / 2) == 0
                let h: CGFloat = isMajor ? 13 : isHalf ? 8 : 4
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height - h)); p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(.primary.opacity(isMajor ? 0.55 : 0.22)), lineWidth: isMajor ? 1 : 0.5)
                if isMajor {
                    let label = Text(i == 0 ? "0" : control.format(v))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.primary.opacity(i == 0 ? 0.7 : 0.4))
                    ctx.draw(label, at: CGPoint(x: x, y: size.height - h - 7))
                }
            }
            var marker = Path()
            marker.move(to: CGPoint(x: mid, y: 2)); marker.addLine(to: CGPoint(x: mid, y: size.height))
            ctx.stroke(marker, with: .color(.primary), lineWidth: 1.5)
        }
        .frame(height: 34)
        .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let base = start ?? value
                    if start == nil { start = value }
                    #if os(macOS)
                    let fine = NSEvent.modifierFlags.contains(.option) ? 0.1 : 1
                    #else
                    let fine = 1.0
                    #endif
                    let next = base - Double(g.translation.width / pointsPerMinor) * minor * fine
                    let step = control == .exposure ? 0.01 : 0.005
                    onChange(min(max((next / step).rounded() * step, control.range.lowerBound), control.range.upperBound))
                }
                .onEnded { _ in
                    start = nil
                    onCommit(value)
                }
        )
        .modifier(ResetOnDoubleClick(reset: onReset))
        #if os(macOS)
        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        .help("Drag left or right. Hold Option for 10× finer. Double-click to reset.")
        #else
        // A tick on every labelled mark, like the level ruler's haptics.
        .sensoryFeedback(.selection, trigger: Int((value / (minor * Double(major))).rounded(.towardZero)))
        #endif
    }
}
