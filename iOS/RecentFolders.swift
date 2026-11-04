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
            items = Self.deduplicated(saved)
            if items.count != saved.count { save() }
        }
    }

    /// Where an entry points now. The stored path can be stale: folders inside the app's own Documents move when
    /// the app is reinstalled or updated (new container), and the bookmark follows them.
    private static func currentPath(_ item: Item) -> String {
        var stale = false
        return (try? URL(resolvingBookmarkData: item.bookmark, bookmarkDataIsStale: &stale))?.standardizedFileURL.path ?? item.path
    }

    /// One entry per folder (newest first), so a folder never shows up twice in Recent.
    private static func deduplicated(_ list: [Item]) -> [Item] {
        var seen = Set<String>()
        return list.filter { seen.insert(currentPath($0)).inserted }
    }

    /// Call after a folder opened (its security scope is held by the Library at that point).
    func add(_ url: URL) {
        guard let bookmark = try? url.bookmarkData() else { return }
        let path = url.standardizedFileURL.path
        items.removeAll { $0.path == path || Self.currentPath($0) == path }
        items.insert(Item(path: path, name: url.lastPathComponent, bookmark: bookmark), at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    /// Recent folders other than the one that's open.
    func others(than folder: URL?) -> [Item] {
        let open = folder?.standardizedFileURL.path
        return items.filter { $0.path != open && Self.currentPath($0) != open }
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

/// Recent folders on the start screen: one rounded card, a black folder glyph per row, hairlines between.
struct RecentFoldersList: View {
    @Environment(Library.self) private var library
    @Environment(\.supportsMultipleWindows) private var multipleWindows
    @Environment(\.openWindow) private var openWindow
    private var recents = RecentFolders.shared

    var body: some View {
        if !recents.items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent").font(.footnote.weight(.semibold)).foregroundStyle(Ink.faint)
                    .padding(.leading, 6)
                VStack(spacing: 0) {
                    ForEach(recents.items) { item in
                        Button { recents.open(item, in: library) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill").font(.system(size: 15))
                                    .frame(width: 34, height: 34)
                                    .background(Ink.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 54)
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
                        if item != recents.items.last { Ink.rule.frame(height: Ink.hairline).padding(.leading, 58) }
                    }
                }
                .background(Ink.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(.horizontal, 24)
        }
    }
}
