import SwiftUI
import UniformTypeIdentifiers

@main
struct HorizonApp: App {
    var body: some Scene {
        // One Library per scene (window), like the Mac's one folder per tab: on iPad two folders can sit side by
        // side in Split View / Stage Manager. The value is set when a folder opens "in a new window".
        WindowGroup(for: FolderLink.self) { $link in
            SceneRoot(link: link)
        }
        .commands { PadCommands() }
    }
}

/// A folder to open in a new window (iPad): the bookmark is what Files hands out; the path is the identity, so
/// asking for a folder that's already in a window brings that window forward.
struct FolderLink: Codable, Hashable {
    var path: String
    var bookmark: Data

    init(_ item: RecentFolders.Item) { path = item.path; bookmark = item.bookmark }

    static func == (a: FolderLink, b: FolderLink) -> Bool { a.path == b.path }
    func hash(into h: inout Hasher) { h.combine(path) }

    func resolve() -> URL? { FolderLink.resolve(bookmark) }

    static func resolve(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
    }
}

/// Folders open in this process's windows, so a new window doesn't reopen one that's already showing.
@MainActor
enum OpenFolders {
    static var paths: [UUID: String] = [:]
}

/// One window: its own Library, its folder remembered per scene (restored after relaunch), falling back to the
/// last folder opened anywhere.
struct SceneRoot: View {
    let link: FolderLink?
    @State private var library = Library()
    @State private var picking = false
    @State private var sceneID = UUID()
    @SceneStorage("folderBookmark") private var sceneFolder: Data?
    @Environment(\.scenePhase) private var phase
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .system

    var body: some View {
        RootView()
            .tint(.primary)
            .preferredColorScheme(appearance.colorScheme)
            .onAppear(perform: restore)
            // Remember it for "Recent" on the start screen and "Switch folder" in ⋯, and for this window.
            .onChange(of: library.folder, initial: true) { _, folder in
                OpenFolders.paths[sceneID] = folder?.path
                guard let folder else { return }
                RecentFolders.shared.add(folder)
                if let bookmark = try? folder.bookmarkData() { sceneFolder = bookmark }
            }
            .onChange(of: phase) { _, p in if p != .active { library.saveNow() } }
            .onDisappear { OpenFolders.paths[sceneID] = nil }
            // ⌘O (File ▸ Open Folder…). On its own view: two file importers on one view don't both work.
            .background { Color.clear.folderPicker(isPresented: $picking) }
            // A folder dragged in from Files opens here (iPad).
            .onDrop(of: [.folder], isTargeted: nil, perform: dropFolder)
            .focusedSceneValue(\.padLibrary, library)
            .focusedSceneValue(\.openFolder, $picking)
            .environment(library)
    }

    private func restore() {
        guard library.folder == nil else { return }
        if let link, let url = link.resolve() { library.open(url); return }
        // A folder passed as `-openFolder <path>` (scripts) wins over the window's own.
        if UserDefaults.standard.string(forKey: "openFolder") == nil, library.reopenLastFolder,
           let data = sceneFolder, let url = FolderLink.resolve(data) {
            library.open(url)
            return
        }
        // A brand-new window while the last folder is open in another one: the start page (like the Mac's new tab),
        // so two windows don't edit the same folder.
        if UserDefaults.standard.string(forKey: "openFolder") == nil,
           let last = UserDefaults.standard.string(forKey: "lastFolder"), OpenFolders.paths.values.contains(last) {
            return
        }
        library.restoreLastFolder()
    }

    private func dropFolder(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.folder.identifier) }) else { return false }
        provider.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.folder.identifier) { url, _, _ in
            // Keep access past this callback: a bookmark made now resolves to a URL we can open.
            guard let url, let data = try? url.bookmarkData() else { return }
            Task { @MainActor in if let resolved = FolderLink.resolve(data) { library.open(resolved) } }
        }
        return true
    }
}

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(\.horizontalSizeClass) private var hSize
    /// Shared with the grid so the editor can zoom out of the tapped tile.
    @Namespace private var zoom

    /// iPad with room (full screen, big Split View / Stage Manager windows): list + editor side by side.
    /// Everything narrower (iPhone, narrow Split View, Slide Over) is the iPhone UI.
    private var twoPane: Bool { UIDevice.current.userInterfaceIdiom == .pad && hSize == .regular }

    var body: some View {
        Group {
            if library.folder == nil {
                StartView()
            } else if twoPane {
                PadRoot()
            } else {
                GridScreen(zoom: zoom)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { !twoPane && library.openedID != nil },
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
    /// iPad two-pane layout: a centred alert (an action sheet there floats as a popover over the whole window).
    var asAlert = false

    func body(content: Content) -> some View {
        let ids = library.pendingDelete ?? []
        let shown = Binding(
            get: { active && library.pendingDelete != nil },
            set: { if !$0 { library.pendingDelete = nil } }
        )
        if asAlert {
            content.alert(library.deleteTitle(ids), isPresented: shown) { buttons(ids) } message: { Text(library.deleteMessage(ids)) }
        } else {
            content.confirmationDialog(library.deleteTitle(ids), isPresented: shown, titleVisibility: .visible) {
                buttons(ids)
            } message: {
                Text(library.deleteMessage(ids))
            }
        }
    }

    @ViewBuilder private func buttons(_ ids: [String]) -> some View {
        Button("Move to Trash", role: .destructive) { library.pendingDelete = nil; library.delete(ids) }
        Button("Move to Trash, Don't Ask Again", role: .destructive) {
            UserDefaults.standard.set(false, forKey: Library.confirmDeleteKey)
            library.pendingDelete = nil
            library.delete(ids)
        }
        Button("Cancel", role: .cancel) { library.pendingDelete = nil }
    }
}

extension View {
    func deleteConfirmation(active: Bool, asAlert: Bool = false) -> some View { modifier(DeleteConfirmation(active: active, asAlert: asAlert)) }
}
