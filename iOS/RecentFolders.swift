import SwiftUI

/// The last few folders opened on the iPhone (no room for tabs). Stored as security-scoped
/// bookmarks, since folders picked in Files can only be reopened through one.
@MainActor
@Observable
final class RecentFolders {
    static let shared = RecentFolders()
    static let limit = 5
    private static let key = "recentFolders"

    struct Item: Codable, Identifiable, Equatable {
        var path: String
        var name: String
        var bookmark: Data
        var id: String { path }
    }

    private(set) var items: [Item] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    /// Call after a folder opened (its security scope is held by the Library at that point).
    func add(_ url: URL) {
        guard let bookmark = try? url.bookmarkData() else { return }
        let path = url.standardizedFileURL.path
        items.removeAll { $0.path == path }
        items.insert(Item(path: path, name: url.lastPathComponent, bookmark: bookmark), at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    /// Recent folders other than the one that's open.
    func others(than folder: URL?) -> [Item] {
        let open = folder?.standardizedFileURL.path
        return items.filter { $0.path != open }
    }

    /// Saves the open folder's state and switches to `item`. A folder that's gone is dropped from the list.
    func open(_ item: Item, in library: Library) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: item.bookmark, bookmarkDataIsStale: &stale) else {
            remove(item)
            library.toast = "“\(item.name)” isn't available any more"
            return
        }
        library.open(url)   // saves the current folder first
        if stale { add(url) }
    }

    func remove(_ item: Item) {
        items.removeAll { $0.path == item.path }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// "Switch folder" in the grid's ⋯ menu.
struct SwitchFolderMenu: View {
    @Environment(Library.self) private var library
    @Environment(\.supportsMultipleWindows) private var multipleWindows
    @Environment(\.openWindow) private var openWindow
    private var recents = RecentFolders.shared

    var body: some View {
        let others = recents.others(than: library.folder)
        if !others.isEmpty {
            Menu {
                ForEach(others) { item in
                    Button { recents.open(item, in: library) } label: { Label(item.name, systemImage: "folder") }
                }
            } label: { Label("Switch folder", systemImage: "arrow.left.arrow.right") }
            // iPad: another window, so two folders can sit side by side.
            if multipleWindows {
                Menu {
                    ForEach(others) { item in
                        Button { openWindow(value: FolderLink(item)) } label: { Label(item.name, systemImage: "folder") }
                    }
                } label: { Label("Open in New Window", systemImage: "macwindow.badge.plus") }
            }
        }
    }
}

/// Recent folders on the start screen: plain rows, hairline separated.
struct RecentFoldersList: View {
    @Environment(Library.self) private var library
    @Environment(\.supportsMultipleWindows) private var multipleWindows
    @Environment(\.openWindow) private var openWindow
    private var recents = RecentFolders.shared

    var body: some View {
        if !recents.items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent").font(.footnote).foregroundStyle(Ink.faint)
                    .padding(.bottom, 6)
                ForEach(recents.items) { item in
                    Button { recents.open(item, in: library) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(item.name).lineLimit(1)
                            Spacer()
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .contextMenu {
                        if multipleWindows {
                            Button { openWindow(value: FolderLink(item)) } label: { Label("Open in New Window", systemImage: "macwindow.badge.plus") }
                        }
                        Button(role: .destructive) { recents.remove(item) } label: { Label("Remove from Recent", systemImage: "minus.circle") }
                    }
                    if item != recents.items.last { Ink.rule.frame(height: Ink.hairline) }
                }
            }
            .padding(.horizontal, 32)
        }
    }
}
