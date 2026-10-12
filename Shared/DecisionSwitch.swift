import SwiftUI

/// "As shot | Leveled +1.3°": a two-sided switch whose filled side is what's applied and on screen, instead of
/// two buttons that read like actions either way. Before deciding, hovering (Mac) or holding (iPhone) a side
/// previews it on the photo through `peek`; releasing a press applies it. Shared by both apps.
struct DecisionSwitch: View {
    let photo: Photo
    var large = false
    let decide: (Decision) -> Void
    let peek: (Double?) -> Void

    @State private var pressed: Decision?

    /// What Level would apply: the angle set by hand, else the suggestion.
    static func levelTarget(_ p: Photo) -> Double {
        p.correction != 0 ? p.correction : (p.detection?.correction ?? 0)
    }

    var body: some View {
        HStack(spacing: 0) {
            side(.keep, title: "As shot", key: "K")
            Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1).padding(.vertical, 6)
            side(.level, title: levelTitle, key: "L")
        }
        .frame(height: large ? 50 : 34)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var levelTitle: String {
        // Before deciding, no number: the headline already says "Looks tilted +0.6°?", and the correction
        // (−0.6°) next to it read like a contradiction.
        photo.decision == .level ? "Leveled " + Geometry.format(photo.correction) : "Level"
    }

    private func angle(for d: Decision) -> Double { d == .level ? Self.levelTarget(photo) : 0 }

    private func side(_ d: Decision, title: String, key: String) -> some View {
        let on = photo.decision == d
        let held = pressed == d
        return HStack(spacing: 6) {
            Text(title).fontWeight(on ? .semibold : .regular).monospacedDigit()
            if !large { Text(key).opacity(0.45) }
        }
        .font(large ? .body : .callout)
        .padding(.horizontal, large ? 12 : 14)
        .frame(maxWidth: large ? .infinity : nil, maxHeight: .infinity)
        .foregroundStyle(on ? Color.primary.opacity(0) : Color.primary)
        .overlay {
            // The applied side is filled (inverted colors), so it reads as a state, not a button.
            if on {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.semibold).monospacedDigit()
                    if !large { Text(key).opacity(0.5) }
                }
                .font(large ? .body : .callout)
                .foregroundStyle(.background)
            }
        }
        .background(on ? Color.primary : (held ? Color.primary.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { inside in if !on { peek(inside ? angle(for: d) : nil) } }
        .onTapGesture { peek(nil); if !on { decide(d) } }
        .help(on ? "Applied" : (d == .level ? "Hover to preview · click or L to level" : "Hover to preview · click or K to keep it as shot"))
        #else
        // Hold to preview; lift to apply (drag away first to cancel).
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if pressed == nil { pressed = d; if !on { peek(angle(for: d)) } }
                }
                .onEnded { g in
                    pressed = nil; peek(nil)
                    if !on, abs(g.translation.width) < 40, abs(g.translation.height) < 40 { decide(d) }
                }
        )
        #endif
        .animation(.easeOut(duration: 0.12), value: on)
    }
}

/// The small dark corner chip over a photo ("Tilted 1.4° · Level", "Leveled · Undo"), like the other overlays.
struct ChipStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(RoundedRectangle(cornerRadius: 4))
    }
}

extension View {
    func chipStyle() -> some View { modifier(ChipStyle()) }
}
