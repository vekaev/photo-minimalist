import AppKit
import SwiftUI

enum ViewMode: String { case list, grid }

/// Root: a start page, or the photo list with a large preview, or (optionally) a grid.
struct ContentView: View {
    @Environment(Library.self) private var library
    @AppStorage("viewMode") private var mode: ViewMode = .list
    @AppStorage("showPreview") private var showPreview = true
    @AppStorage("sidebarWidth") private var sidebarWidth = 320.0

    var body: some View {
        @Bindable var library = library
        Group {
            if library.folder == nil {
                StartPage()
            } else if showPreview {
                // Sidebar (list or a small grid) + preview; drag the divider to resize the sidebar.
                HStack(spacing: 0) {
                    Group {
                        if mode == .grid { GridPage(mode: $mode, showPreview: $showPreview) }
                        else { PhotoList(mode: $mode, showPreview: $showPreview) }
                    }
                    .frame(width: sidebarWidth)
                    .background(Theme.panel)
                    SidebarDivider(width: $sidebarWidth)
                    if let p = library.photo(library.openedID) {
                        PhotoView(photo: p)
                    } else {
                        Text("Select a photo").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else if mode == .grid {
                GridPage(mode: $mode, showPreview: $showPreview)
            } else {
                PhotoList(mode: $mode, showPreview: $showPreview)
                    .background(Theme.ground)
            }
        }
        .background(Theme.ground)
        // Space: the photo floats above the list instead of replacing it.
        .overlay { QuickLook() }
        .inspector(isPresented: $library.showSettings) {
            // A fixed width: with min/ideal/max the panel snapped back to "ideal" every time its
            // content redrew (e.g. on each tick of the Original slider), making the whole window jump.
            SettingsPanel().inspectorColumnWidth(300)
        }
        .sheet(isPresented: $library.showExport) { ExportView() }
        // Right-click the preview's control bar, ⋯ ▸ Customize Controls…, or View ▸ Customize Controls….
        .sheet(isPresented: $library.showControls) { CustomizeControlsView() }
        // View ▸ History (⌘Y): the folder's activity with Revert.
        .sheet(isPresented: $library.showActivity) { ActivityView(photoID: library.openedID) }
        .dropDestination(for: URL.self) { urls, _ in
            // In this tab if it's empty, else each folder in its own new tab.
            let folders = urls.filter(\.hasDirectoryPath)
            guard !folders.isEmpty else { return false }
            WindowRouter.shared.open(folders, from: library)
            return true
        }
        // The list order is frozen per filter, so deciding a photo doesn't make the list jump.
        .onChange(of: library.filter, initial: true) { refreshList() }
        .onChange(of: library.folder) { refreshList() }
        .onChange(of: library.photos.count) { refreshList() }
        .onChange(of: library.reviewOrder) { refreshList(keepSelection: true) }
        // Re-sort once the background check finishes, so new suggestions move to the top.
        .onChange(of: library.isAnalyzing) { _, busy in if !busy && library.filter == .review { refreshList(keepSelection: true) } }
        .overlay(alignment: .bottom) { CardBanner() }
        .overlay(alignment: .bottom) { Toast() }
    }

    private func refreshList(keepSelection: Bool = false) {
        library.navigation = library.visible.map(\.id)
        if keepSelection, library.openedID != nil, library.navigation.contains(library.openedID!) { return }
        if library.openedID == nil || !library.navigation.contains(library.openedID!) {
            library.openedID = mode == .list ? library.navigation.first : nil
            // The list highlights the selection too: start it over with the new current photo.
            if mode == .list { library.selection = library.openedID.map { [$0] } ?? [] }
        }
    }
}

// MARK: Quick look

/// A floating window over the app: dimmed backdrop, rounded card. Space, Esc or a click outside closes it.
private struct QuickLook: View {
    @Environment(Library.self) private var library

    var body: some View {
        let open = library.quickLook
        GeometryReader { geo in
            ZStack {
                if open {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        .onTapGesture { library.quickLook = false }
                        .transition(.opacity)
                }
                if open, let p = library.photo(library.openedID) {
                    PhotoView(photo: p, floating: true)
                        .frame(width: geo.size.width * 0.84, height: geo.size.height * 0.86)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
                        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
                        // Opens with a gentle scale-up; closes a little faster with a slight shrink.
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.96).combined(with: .opacity),
                            removal: .scale(scale: 0.98).combined(with: .opacity)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Only this layer animates, so nothing else in the window moves.
        .animation(open ? .spring(response: 0.26, dampingFraction: 0.86) : .easeOut(duration: 0.15), value: open)
        .allowsHitTesting(open)
    }
}

// MARK: Toast

/// A short confirmation at the bottom ("Copied photo"), gone after a moment.
private struct Toast: View {
    @Environment(Library.self) private var library

    var body: some View {
        ZStack {
            if let text = library.toast {
                Text(text)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Theme.line))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                    .padding(.bottom, library.cardOffer == nil ? 24 : 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(text.hasSuffix("…") ? 30 : 2.2))
                        if library.toast == text { library.toast = nil }
                    }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: library.toast)
        .allowsHitTesting(false)
    }
}

// MARK: Memory card banner

/// "Memory card · 100_FUJI · 969 photos  [Open]  ✕": small, at the bottom, never in the way.
private struct CardBanner: View {
    @Environment(Library.self) private var library

    var body: some View {
        if let offer = library.cardOffer {
            HStack(spacing: 12) {
                Image(systemName: "sdcard").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Memory card “\(offer.volumeName)”").font(.callout.weight(.medium))
                    Text("\(offer.folder.lastPathComponent) · \(offer.photoCount) photos").font(.caption).foregroundStyle(.secondary)
                }
                Button { WindowRouter.shared.open(offer.folder, from: library); library.cardOffer = nil } label: {
                    Text("Open").fontWeight(.medium).padding(.horizontal, 14).padding(.vertical, 5)
                        .foregroundStyle(Theme.ground).background(Color.primary, in: Capsule())
                }
                .buttonStyle(.plain)
                Button { library.cardOffer = nil } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Dismiss. Change this in Settings → Memory card.")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.line))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: offer.folder) {
                try? await Task.sleep(for: .seconds(45))
                if library.cardOffer == offer { withAnimation { library.cardOffer = nil } }
            }
        }
    }
}

// MARK: Start

private struct StartPage: View {
    @Environment(Library.self) private var library

    var body: some View {
        VStack(spacing: 22) {
            LevelMark().frame(width: 132, height: 44)
            VStack(spacing: 6) {
                Text("Photo Minimalist").font(.system(size: 28, weight: .semibold))
                Text("Preview, level, crop. Nothing else.")
                    .foregroundStyle(.secondary)
            }
            Button { library.chooseFolder() } label: {
                Text("Open folder…").fontWeight(.medium)
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .foregroundStyle(Theme.ground)
                    .background(Color.primary, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o")
            Text("or drop a folder here").font(.callout).foregroundStyle(.tertiary)
            if let notice = library.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The app's mark: a horizon line broken by a level bubble.
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

// MARK: Shared header (filter tabs, List | Grid)

private struct PageHeader: View {
    @Environment(Library.self) private var library
    @Binding var mode: ViewMode
    var showPreview: Binding<Bool>? = nil

    var body: some View {
        // Just the filter tabs and List | Grid: the folder's name is on its tab in the top bar,
        // the preview toggle, progress and ⋯ menu are there too (FolderWindows.swift).
        VStack(alignment: .leading, spacing: 0) {
            // Tabs, with List | Grid right above the photos. Labels never wrap: if the counts don't fit,
            // only the selected tab keeps its count.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { tabRow(allCounts: true); viewSwitcher }
                HStack(spacing: 10) { tabRow(allCounts: false); viewSwitcher }
                tabRow(allCounts: false)
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)   // the List | Grid icons sit close to the edge
            Theme.line.frame(height: 1)
        }
    }

    /// List | Grid, the current one highlighted (like Finder), instead of a toggle that shows the other view.
    private var viewSwitcher: some View {
        // Light: two small icons, the current one on a faint square. No heavy container box.
        HStack(spacing: 0) {
            ForEach([ViewMode.list, .grid], id: \.self) { m in
                Button { mode = m } label: {
                    Image(systemName: m == .list ? "list.bullet" : "square.grid.2x2")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 20, height: 18).contentShape(Rectangle())
                        .foregroundStyle(mode == m ? .primary : .tertiary)
                        .background(mode == m ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help(m == .list ? "List" : "Grid")
            }
        }
        .fixedSize()
        // Centered on the labels' text, not on the row with its underline.
        .offset(y: -1)
    }

    private func tabRow(allCounts: Bool) -> some View {
        HStack(spacing: 14) {
            ForEach(Filter.allCases) { f in
                let selected = library.filter == f
                Button { library.filter = f } label: {
                    HStack(spacing: 4) {
                        // A heart instead of the word keeps the row on one line in the 320 pt list.
                        if f == .favorites {
                            Image(systemName: selected ? "heart.fill" : "heart").accessibilityLabel(f.label)
                        } else {
                            Text(f.label)
                        }
                        if allCounts || selected {
                            Text("\(library.count(f))").foregroundStyle(.tertiary).monospacedDigit()
                        }
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(selected ? Color.primary : .clear).frame(height: 1.5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(f == .favorites ? "Favorites (F marks a photo)" : "")
            }
            // The crop-versions collection isn't a tab: say what's shown (any tab leaves it).
            if library.filter == .crops {
                Text("Crop versions · \(library.count(.crops))")
                    .font(.callout.weight(.semibold)).monospacedDigit()
                    .lineLimit(1).fixedSize()
            }
            Spacer(minLength: 0)
        }
    }
}

struct MoreMenu: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        Menu {
            Button("View Options  S") { withAnimation { library.showSettings.toggle() } }
            Button("Customize Controls…") { library.showControls = true }.disabled(library.folder == nil)
            SettingsLink { Text("Settings…  ⌘,") }
            Divider()
            Button("Open folder…") { library.chooseFolder() }
            Button("Export \(library.toExport.count) leveled…") { library.showExport = true }
                .disabled(library.toExport.isEmpty)
            Divider()
            Picker("Review order", selection: $library.reviewOrder) {
                ForEach(ReviewOrder.allCases) { Text($0.label).tag($0) }
            }
            Button("Apply all suggestions") { library.applyAllSuggestions() }
            // A collection, not a tab: photos with two or more crop versions. Any tab leaves it.
            Toggle("Photos with crop versions (\(library.count(.crops)))", isOn: Binding(
                get: { library.filter == .crops },
                set: { library.filter = $0 ? .crops : .all }))
            PhotosMenu()
            Button("Undo") { library.undo() }.disabled(!library.canUndo)
            Button("Redo") { library.redo() }.disabled(!library.canRedo)

        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

// MARK: List (left column)

struct PhotoList: View {
    @Environment(Library.self) private var library
    @Binding var mode: ViewMode
    @Binding var showPreview: Bool
    @FocusState private var focused: Bool
    @State private var clicked: String?
    @State private var anchor: String?
    /// The list's width: with the whole window it shows Finder-like info columns, as many as fit.
    @State private var listWidth: CGFloat = 0

    var body: some View {
        let columns: [InfoColumn] = showPreview ? [] : InfoColumn.fitting(listWidth)
        VStack(spacing: 0) {
            PageHeader(mode: $mode, showPreview: $showPreview)
            if library.navigation.isEmpty {
                Text(library.filter == .review ? (library.isAnalyzing ? "Looking for horizons…" : "Nothing looks tilted.") : library.filter == .leveled ? "Nothing edited yet." : "Nothing here.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if !columns.isEmpty { InfoColumnHeader(columns: columns) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(library.sections(library.navigation.compactMap(library.photo), filter: library.filter)) { section in
                                if let title = section.title { SectionHeading(title: title) }
                                ForEach(section.photos) { p in
                                    Row(photo: p, selected: library.openedID == p.id || library.selection.contains(p.id), columns: columns)
                                        .id(p.id)
                                        .onTapGesture { clicked = p.id; click(p.id) }
                                        .contextMenu { StatusMenu(ids: library.targets(for: p.id)) }
                                }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: library.openedID) { _, id in
                        // Follow keyboard moves (↑↓, decisions); a clicked row is already in view.
                        defer { clicked = nil }
                        guard let id, id != clicked else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
        // Without the preview the list itself takes the keyboard.
        .focusable(!showPreview)
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { if !showPreview { focused = true } }
        .onChange(of: showPreview) { _, shown in focused = !shown }
        .onChange(of: library.quickLook) { _, open in if !open && !showPreview { focused = true } }
        .onKeyPress { press in
            guard !showPreview, let id = library.openedID else { return .ignored }
            switch press.key {
            case .upArrow, .leftArrow: library.step(-1); return .handled
            case .downArrow, .rightArrow: library.step(1); return .handled
            case .space, .return: library.quickLook = true; return .handled
            default: break
            }
            let chosen = library.targets(for: id)
            if press.key == .delete || press.key == .deleteForward { library.requestDelete(chosen); return .handled }
            if press.characters.lowercased() == "f" { library.toggleFavorite(chosen); return .handled }
            let d: Decision
            switch press.characters.lowercased() {
            case "l": d = .level
            case "k": d = .keep
            case "u": d = .undecided
            default: return .ignored
            }
            library.decideAndMove(chosen, d)
            return .handled
        }
    }

    /// Click: one photo. ⌘-click adds or removes it, ⇧-click selects the run from the last click. The opened
    /// photo (preview, keyboard) stays a single "current" one; actions act on the whole selection.
    private func click(_ id: String) {
        let flags = NSEvent.modifierFlags
        let ids = library.navigation
        if flags.contains(.command) {
            if library.selection.isEmpty, let current = library.openedID { library.selection = [current] }
            if library.selection.contains(id), library.selection.count > 1 {
                library.selection.remove(id)
                if library.openedID == id { library.openedID = ids.last { library.selection.contains($0) } }
            } else {
                library.selection.insert(id)
                library.openedID = id
            }
            anchor = id
        } else if flags.contains(.shift), let a = anchor ?? library.openedID,
                  let i = ids.firstIndex(of: a), let j = ids.firstIndex(of: id) {
            library.selection = Set(ids[min(i, j)...max(i, j)])
            library.openedID = id
        } else {
            library.selection = [id]
            library.openedID = id
            anchor = id
            // A plain click always shows the photo: with the preview hidden, it opens next to the list.
            if !showPreview { withAnimation(.easeOut(duration: 0.2)) { showPreview = true } }
        }
    }
}

private struct Row: View {
    @Environment(Library.self) private var library
    let photo: Photo
    let selected: Bool
    /// Info columns (full-width list); none = one extra summary line under the status instead.
    var columns: [InfoColumn] = []

    var body: some View {
        HStack(spacing: 10) {
            PhotoThumb(photo: photo, maxPixel: 160, showSuggestion: false)
                .frame(width: 58, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(photo.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    if let tag = photo.companionTag { RawTag(text: tag) }
                    if photo.favorite { FavoriteMark() }
                }
                Text(library.note(for: photo)).font(.caption)
                    .foregroundStyle(photo.decision == .undecided ? .secondary : .primary)
                    .lineLimit(1)
                if columns.isEmpty {
                    // "Oct 3, 14:22 · 23 mm ƒ/2.8 1/250 ISO 400"; a blank line until read, so rows don't jump.
                    Text(photo.info?.summaryLine ?? " ").font(.caption).monospacedDigit()
                        .foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !columns.isEmpty { InfoColumnCells(photo: photo, columns: columns) }
        }
        .task(id: photo.url) { await library.fillInfo(photo) }
        .padding(6)
        .background(selected ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

/// A quiet heading between groups of photos, e.g. "Looks tilted · 213".
struct SectionHeading: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.medium)).tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small "+ RAF" mark: this JPEG has a RAW twin that's handled with it.
struct RawTag: View {
    let text: String
    var body: some View {
        Text("+ " + text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line))
            .fixedSize()
            .help("Shown as the JPEG. The \(text) file with the same name is part of this photo.")
    }
}

/// The one accent in the UI: a small red heart on favorites.
struct FavoriteMark: View {
    var size: CGFloat = 10
    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.red)
            .help("Favorite (Red tag in Finder)")
    }
}

/// Right-click (two-finger click) menu for one or more photos.
struct StatusMenu: View {
    @Environment(Library.self) private var library
    let ids: [String]

    var body: some View {
        let suffix = ids.count > 1 ? " \(ids.count) photos" : ""
        Button("Level" + suffix) { library.decideAndMove(ids, .level) }
        Button("Keep as shot" + suffix) { library.decideAndMove(ids, .keep) }
        Button("Undecided" + suffix) { library.decideAndMove(ids, .undecided) }
        Divider()
        let photos = ids.compactMap(library.photo)
        Button((photos.contains { !$0.favorite } ? "Favorite" : "Unfavorite") + suffix) { library.toggleFavorite(ids) }
        Divider()
        Button("Copy" + suffix) { library.copyPhotos(photos, kind: .asShown) }
        Button("Copy Original" + suffix) { library.copyPhotos(photos, kind: .original) }
        if photos.contains(where: { $0.rawCompanion != nil }) {
            Button("Copy RAW File" + (ids.count > 1 ? "s" : "")) { library.copyPhotos(photos, kind: .raw) }
        }
        Divider()
        if !library.savable(ids).isEmpty {
            Button("Save to Original" + suffix) { Task { await library.saveToOriginalsWithToast(ids) } }
        }
        if photos.contains(where: library.hasBackup) {
            Button("Restore Original" + suffix) { library.restoreOriginals(ids) }
        }
        Button("Reset Decision" + suffix) { library.resetToOriginal(ids) }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(photos.map(\.url)) }
        Button("Add to Photos" + suffix) { library.addToPhotos(ids) }
        Divider()
        Button("Move to Trash") { library.requestDelete(ids) }
    }
}

/// Apple Photos: add the selection / favorites / everything (originals, RAW as the alternate), or mark
/// favorites on copies already there.
struct PhotosMenu: View {
    @Environment(Library.self) private var library

    var body: some View {
        let selected = library.copyTargets(preferOpened: false).map(\.id)
        let favorites = library.photos.filter(\.favorite).map(\.id)
        Menu("Apple Photos") {
            Button("Add \(selected.count == 1 ? "This Photo" : "\(selected.count) Selected")") { library.addToPhotos(selected) }
                .disabled(selected.isEmpty)
            Button("Add \(favorites.count) Favorites") { library.addToPhotos(favorites) }.disabled(favorites.isEmpty)
            Button("Add All \(library.photos.count)") { library.addToPhotos(library.photos.map(\.id)) }
            Divider()
            Button("Mark Favorites in Photos") { library.syncFavoritesToPhotos() }.disabled(favorites.isEmpty)
        }
    }
}

/// A photo as it will be exported (rotated and cropped once leveled), optionally with the suggested horizon.
struct PhotoThumb: View {
    @Environment(Library.self) private var library
    let photo: Photo
    let maxPixel: Int
    var showSuggestion = true
    /// Whole photo inside the tile (portraits smaller, nothing cut off) instead of cropping to fill.
    var fit = false
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if fit { Theme.raised.opacity(0.55) } else { Theme.raised }
            if let image {
                // The photo as it will be saved (rotation + crop), fitted whole or cropped to fill the tile.
                let aspect = Geometry.finalAspect(CGFloat(image.width) / CGFloat(image.height), crop: photo.appliedCrop)
                Color.clear
                    .aspectRatio(aspect, contentMode: fit ? .fit : .fill)
                    .overlay { EditedImage(image: image, rotation: photo.appliedCorrection, crop: photo.appliedCrop) }
                    .clipped()
                    .overlay {
                        if showSuggestion, library.hasSuggestion(photo), let d = photo.detection { HorizonLine(degrees: d.angle) }
                    }
            }
        }
        .clipped()
        .task(id: photo.url) {
            if maxPixel > 200, image == nil {
                image = await ImageCache.shared.image(for: photo.url, rawCompanion: photo.rawCompanion, maxPixel: 160)
            }
            if let sharp = await ImageCache.shared.image(for: photo.url, rawCompanion: photo.rawCompanion, maxPixel: maxPixel) {
                image = sharp
            }
        }
    }
}

/// Tags drawn on a tile: a confident tilt ("+3.5°"), "✓ −2.4°" or "Kept", "RAF" and ♥.
struct TileTags: View {
    @Environment(Library.self) private var library
    let photo: Photo

    var body: some View {
        HStack(alignment: .top) {
            if let raw = photo.companionTag {
                Text(raw).font(.system(size: 9, weight: .semibold)).tracking(0.3)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 3))
            }
            if photo.favorite {
                FavoriteMark(size: 12).shadow(color: .black.opacity(0.5), radius: 2)
            }
            Spacer(minLength: 4)
            if let tag = library.tag(for: photo) {
                let filled = tag.kind == .leveled
                Text(tag.text)
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(filled ? Color.black : .white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(filled ? Color.white : Color.black.opacity(0.5), in: Capsule())
                    .help(library.note(for: photo))
            }
        }
        .padding(7)
        .allowsHitTesting(false)
    }
}

/// Dashed line through the center at `degrees` (counter-clockwise positive), readable on any photo.
struct HorizonLine: View {
    let degrees: Double
    var body: some View {
        GeometryReader { geo in
            let r = degrees * .pi / 180
            let len = hypot(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let dx = cos(r) * len / 2, dy = -sin(r) * len / 2
            let path = Path { p in
                p.move(to: CGPoint(x: c.x - dx, y: c.y - dy))
                p.addLine(to: CGPoint(x: c.x + dx, y: c.y + dy))
            }
            path.stroke(.black.opacity(0.45), style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
            path.stroke(.white, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        }
        .allowsHitTesting(false)
    }
}

// MARK: Grid (optional)

private struct GridPage: View {
    @Environment(Library.self) private var library
    @Binding var mode: ViewMode
    var showPreview: Binding<Bool>? = nil
    @FocusState private var focused: Bool
    @State private var columns = 4
    @State private var anchor: String?

    /// Next to the preview: small tiles, and selecting a tile shows it in the preview.
    private var inSidebar: Bool { showPreview?.wrappedValue == true }
    private var minCell: CGFloat { inSidebar ? 120 : 300 }
    private let spacing: CGFloat = 8, pad: CGFloat = 16
    @State private var hovered: String?
    @AppStorage("thumbFill") private var thumbFill = false
    @State private var scrollTarget: String?

    var body: some View {
        let ids = library.navigation
        VStack(spacing: 0) {
            PageHeader(mode: $mode, showPreview: showPreview)
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: minCell), spacing: spacing)], alignment: .leading, spacing: spacing) {
                            ForEach(library.sections(ids.compactMap(library.photo), filter: library.filter)) { section in
                                Section {
                                    ForEach(section.photos) { p in cell(p).id(p.id) }
                                } header: {
                                    if let title = section.title { SectionHeading(title: title).padding(.top, 6) }
                                }
                            }
                        }
                        .padding(pad)
                    }
                    // Scroll only when the arrow keys moved the selection; a click is already on screen.
                    .onChange(of: scrollTarget) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                        scrollTarget = nil
                    }
                }
                // Measured live, so ↑↓ always move by a real row (a stale count made ↓ act like →).
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                    columns = max(1, Int((w - pad * 2 + spacing) / (minCell + spacing)))
                    library.gridColumns = columns
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true; library.gridActive = true }
        .onDisappear { library.gridActive = false }
        // Moving through photos in quick look keeps the grid's selection in view.
        .onChange(of: library.openedID) { _, id in
            if library.quickLook, let id { library.selection = [id]; scrollTarget = id }
        }
        .onChange(of: library.quickLook) { _, open in if !open { focused = true } }
        .onKeyPress { handle($0, ids) }
    }

    /// Photo only. Tags sit on the photo; the name appears on hover or when selected.
    private func cell(_ p: Photo) -> some View {
        let selected = library.selection.contains(p.id)
        let showName = selected || hovered == p.id
        return Color.clear
            .aspectRatio(3 / 2, contentMode: .fit)          // every tile the same shape, portraits included
            .overlay { PhotoThumb(photo: p, maxPixel: 420, showSuggestion: showName, fit: !thumbFill) }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .top) { TileTags(photo: p) }
            .overlay(alignment: .bottomLeading) {
                if showName {
                    Text(p.name).font(.caption.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5))
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.primary : .clear, lineWidth: 2).padding(-3))
            .onHover { inside in hovered = inside ? p.id : (hovered == p.id ? nil : hovered) }
            .contentShape(Rectangle())
        // One gesture: select immediately; the second click of a double-click opens. (Separate single and
        // double tap gestures made SwiftUI hold every click for the double-click interval.)
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { open(p.id) } else { click(p.id) }
        }
        .contextMenu { StatusMenu(ids: library.selection.contains(p.id) ? Array(library.selection) : [p.id]) }
    }

    private func open(_ id: String) {
        library.openedID = id
        if !inSidebar { mode = .list }
    }

    private func click(_ id: String) {
        focused = true
        let flags = NSEvent.modifierFlags
        let ids = library.navigation
        if flags.contains(.command) {
            if library.selection.contains(id) { library.selection.remove(id) } else { library.selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let a = anchor, let i = ids.firstIndex(of: a), let j = ids.firstIndex(of: id) {
            library.selection = Set(ids[min(i, j)...max(i, j)])
        } else {
            library.selection = [id]; anchor = id
            if inSidebar { library.openedID = id }
        }
    }

    private func handle(_ press: KeyPress, _ ids: [String]) -> KeyPress.Result {
        let current = ids.firstIndex { library.selection.contains($0) }
        func move(_ d: Int) -> KeyPress.Result {
            guard !ids.isEmpty else { return .handled }
            let i = min(max((current ?? -d.signum()) + d, 0), ids.count - 1)
            library.selection = [ids[i]]; anchor = ids[i]
            if inSidebar { library.openedID = ids[i] }
            scrollTarget = ids[i]
            return .handled
        }
        if press.modifiers.contains(.command) {
            if press.characters == "a" { library.selection = Set(ids); return .handled }
            return .ignored
        }
        switch press.key {
        case .leftArrow: return move(-1)
        case .rightArrow: return move(1)
        case .upArrow: return move(-columns)
        case .downArrow: return move(columns)
        case .return:
            if let i = current { open(ids[i]) }
            return .handled
        case .escape: library.selection = []; return .handled
        case .delete, .deleteForward:
            library.requestDelete(ids.filter { library.selection.contains($0) })
            return .handled
        case .space:
            if let i = current { library.openedID = ids[i]; library.quickLook = true }
            return .handled
        default: break
        }
        let chosen = ids.filter { library.selection.contains($0) }
        switch press.characters.lowercased() {
        case "l": library.decideAndMove(chosen, .level)
        case "k": library.decideAndMove(chosen, .keep)
        case "u": library.decideAndMove(chosen, .undecided)
        case "f": library.toggleFavorite(chosen)
        default: return .ignored
        }
        return .handled
    }
}

/// The line between the sidebar and the preview. Drag to resize (remembered); double-click for the default width.
private struct SidebarDivider: View {
    @Binding var width: Double
    @State private var start: Double?

    var body: some View {
        Theme.line.frame(width: 1)
            .frame(width: 9).contentShape(Rectangle())
            .padding(.horizontal, -4)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        if start == nil { start = width }
                        let maxWidth = Double((NSApp.keyWindow?.frame.width ?? 1600) * 0.6)
                        width = min(max((start ?? width) + g.translation.width, 240), max(maxWidth, 240))
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture { if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { width = 320 } }
            .zIndex(1)
    }
}
