import SwiftUI

/// The whole first screen: a mark, one sentence, one button.
struct StartView: View {
    @State private var picking = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            LevelMark().frame(width: 120, height: 40)
            VStack(spacing: 8) {
                Text("Photo Minimalist").font(.system(size: 34, weight: .semibold))
                Text("Preview, level, crop. Nothing else.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            RecentFoldersList()
            Button { picking = true } label: {
                Text("Open folder")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(Color(.systemBackground))
                    .background(Color.primary, in: Capsule())
            }
            .padding(.horizontal, 32)
            Text("Originals are never changed.")
                .font(.footnote).foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .padding()
        .folderPicker(isPresented: $picking)
    }
}

/// The icon's mark: a horizon line broken by a level bubble.
struct LevelMark: View {
    var lineWidth: CGFloat = 2.5

    var body: some View {
        Canvas { ctx, size in
            // The app icon's lens: a sunset split by a dead-level horizon.
            let r = min(size.width, size.height) / 2, c = CGPoint(x: size.width / 2, y: size.height / 2)
            let horizon = c.y + r * 0.12, gap = max(1.5, r * 0.07)
            let disc = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.clip(to: disc)
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: horizon - gap / 2)),
                     with: .linearGradient(Gradient(colors: [Color(red: 1, green: 0.77, blue: 0.25), Color(red: 1, green: 0.42, blue: 0.32), Color(red: 0.93, green: 0.21, blue: 0.47)]),
                                           startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: horizon)))
            let sun = r * 0.34
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - sun, y: horizon - gap / 2 - sun, width: 2 * sun, height: 2 * sun)), with: .color(Color(red: 1, green: 0.93, blue: 0.78)))
            ctx.fill(Path(CGRect(x: 0, y: horizon - gap / 2, width: size.width, height: gap)), with: .color(.white))
            ctx.fill(Path(CGRect(x: 0, y: horizon + gap / 2, width: size.width, height: size.height)),
                     with: .linearGradient(Gradient(colors: [Color(red: 0.25, green: 0.47, blue: 1), Color(red: 0.18, green: 0.2, blue: 0.77)]),
                                           startPoint: CGPoint(x: c.x, y: horizon), endPoint: CGPoint(x: c.x, y: c.y + r)))
        }
        .accessibilityHidden(true)
    }
}
