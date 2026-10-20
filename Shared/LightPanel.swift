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
        Slider(value: Binding(get: { v }, set: { new in
            var a = held ?? value
            a[control] = snapped(new)
            held = a
            onChange(a)
        }), in: control.range) { editing in
            if !editing {
                let a = held ?? value
                held = nil
                onCommit(a)
            }
        }
        .controlSize(.small)
        #if os(macOS)
        .simultaneousGesture(TapGesture(count: 2).onEnded { reset() })
        #else
        // A tick when the slider reaches (or leaves) 0.
        .sensoryFeedback(.selection, trigger: v == 0)
        #endif
    }

    /// Within 2 % of the range from 0 counts as 0, so the middle is easy to hit.
    private func snapped(_ x: Double) -> Double {
        let span = control.range.upperBound - control.range.lowerBound
        return abs(x) < span * 0.02 ? 0 : x
    }

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
