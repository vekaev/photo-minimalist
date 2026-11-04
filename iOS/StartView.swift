import SwiftUI

/// The whole first screen, Stoic-like: an ink drawing, a bold lowercase headline, recent folders on a card,
/// one black pill. Paper off-white by day, black at night.
struct StartView: View {
    @Environment(Library.self) private var library
    @State private var picking = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            StartArt().frame(width: 120, height: 56)
                .padding(.bottom, 28)
            InkHeadline(text: "photo minimalist.", size: 38)
            Text("Preview, level, crop. Nothing else.")
                .font(.body).foregroundStyle(.secondary)
                .padding(.top, 6)
            if let notice = library.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.top, 14).padding(.horizontal, 32)
            }
            Spacer(minLength: 24)
            RecentFoldersList()
                .padding(.bottom, 18)
            Button { picking = true } label: {
                Text("Open folder")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(Ink.paper)
                    .background(Color.primary, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(InkPress())
            .hoverEffect(.lift)
            .padding(.horizontal, 24)
            Text("Originals are never changed.")
                .font(.footnote).foregroundStyle(.tertiary)
                .padding(.top, 12).padding(.bottom, 8)
        }
        .padding(.vertical)
        // iPad: a column, not a full-width button.
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .background(Ink.paper.ignoresSafeArea())
        .folderPicker(isPresented: $picking)
    }
}
