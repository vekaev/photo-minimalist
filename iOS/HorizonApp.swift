import SwiftUI

@main
struct HorizonApp: App {
    @State private var library = Library()
    @Environment(\.scenePhase) private var phase
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .system

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .tint(.primary)
                .preferredColorScheme(appearance.colorScheme)
                .onAppear { library.restoreLastFolder() }
                // Remember it for "Recent" on the start screen and "Switch folder" in ⋯.
                .onChange(of: library.folder, initial: true) { _, folder in if let folder { RecentFolders.shared.add(folder) } }
                .onChange(of: phase) { _, p in if p != .active { library.saveNow() } }
        }
    }
}

struct RootView: View {
    @Environment(Library.self) private var library
    /// Shared with the grid so the editor can zoom out of the tapped tile.
    @Namespace private var zoom

    var body: some View {
        Group {
            if library.folder == nil {
                StartView()
            } else {
                GridScreen(zoom: zoom)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { library.openedID != nil },
            set: { if !$0 { library.closePhoto() } }
        )) {
            EditorView().environment(library)
                .zoomTransition(from: library.openedID, in: zoom)
                .overlay(alignment: .top) { ToastView() }
        }
        .overlay(alignment: .top) { ToastView() }
    }
}

extension View {
    /// iOS 18+: the editor grows out of the tapped photo and shrinks back into it, like Photos.
    @ViewBuilder func zoomTransition(from id: String?, in ns: Namespace.ID) -> some View {
        if #available(iOS 18.0, *), let id { navigationTransition(.zoom(sourceID: id, in: ns)) } else { self }
    }

    @ViewBuilder func zoomSource(_ id: String, in ns: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { matchedTransitionSource(id: id, in: ns) } else { self }
    }
}

/// A short confirmation at the top ("Copied photo"), gone after a moment.
struct ToastView: View {
    @Environment(Library.self) private var library

    var body: some View {
        ZStack {
            if let text = library.toast {
                // After a deletion: "Moved 3 to the Trash · Undo" for a few seconds (shake-to-undo isn't reliable).
                let undoable = text == library.undoableToast
                HStack(spacing: 12) {
                    Text(text)
                    if undoable {
                        Button("Undo") { library.toast = nil; library.undo() }
                            .fontWeight(.semibold)
                    }
                }
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, undoable ? 10 : 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(text.hasSuffix("…") ? 30 : undoable ? 5 : 2))
                    if library.toast == text { library.toast = nil }
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: library.toast)
        .allowsHitTesting(library.toast != nil && library.toast == library.undoableToast)
    }
}

/// Monochrome, hairline styling shared by the iPhone screens.
enum Ink {
    static let hairline: CGFloat = 1 / 3
    static let rule = Color.primary.opacity(0.12)
    static let faint = Color.primary.opacity(0.45)
}

struct FolderPicker: ViewModifier {
    @Environment(Library.self) private var library
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.open(url) }
        }
    }
}

extension View {
    func folderPicker(isPresented: Binding<Bool>) -> some View { modifier(FolderPicker(isPresented: isPresented)) }
}

/// "Move 3 photos to the Trash?" for `Library.pendingDelete`. Attached where it can present: the grid when no
/// photo is open, the editor otherwise.
struct DeleteConfirmation: ViewModifier {
    @Environment(Library.self) private var library
    let active: Bool

    func body(content: Content) -> some View {
        let ids = library.pendingDelete ?? []
        content.confirmationDialog(library.deleteTitle(ids), isPresented: Binding(
            get: { active && library.pendingDelete != nil },
            set: { if !$0 { library.pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { library.pendingDelete = nil; library.delete(ids) }
            Button("Move to Trash, Don't Ask Again", role: .destructive) {
                UserDefaults.standard.set(false, forKey: Library.confirmDeleteKey)
                library.pendingDelete = nil
                library.delete(ids)
            }
            Button("Cancel", role: .cancel) { library.pendingDelete = nil }
        } message: {
            Text(library.deleteMessage(ids))
        }
    }
}

extension View {
    func deleteConfirmation(active: Bool) -> some View { modifier(DeleteConfirmation(active: active)) }
}
