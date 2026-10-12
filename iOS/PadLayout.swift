import SwiftUI
import UniformTypeIdentifiers

/// iPad with room (regular width): the folder's photos in a sidebar (tabs, list or grid) and the editor beside it,
/// like the Mac's list + preview. The sidebar hides with the button at the editor's top left.
struct PadRoot: View {
    @Environment(Library.self) private var library
    @State private var columns: NavigationSplitViewVisibility = .all
    @AppStorage("ipad.sidebarGrid") private var grid = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            PadSidebar(grid: $grid)
                .navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 440)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .toolbar(.hidden, for: .navigationBar)
        }
        .navigationSplitViewStyle(.balanced)
        .deleteConfirmation(active: true, asAlert: true)
        // ⋯ ▸ History with no photo shown (an empty tab); the editor shows its own otherwise.
        .sheet(isPresented: Binding(get: { library.showActivity && library.photo(library.openedID) == nil },
                                    set: { if !$0 { library.showActivity = false } })) {
            ActivityView().environment(library)
        }
        // Bare ⌫ also moves to the Trash (the Photo menu shows ⌘⌫).
        .background {
            Button("Move to Trash") { if let id = library.openedID { library.requestDelete([id]) } }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(library.openedID == nil || library.showSettings || library.showActivity || library.pendingDelete != nil)
                .opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var detail: some View {
        let chrome = PadChrome(sidebarShown: columns != .detailOnly) {
            withAnimation(.easeOut(duration: 0.25)) { columns = columns == .detailOnly ? .all : .detailOnly }
        }
        if library.photo(library.openedID) != nil {
            EditorView(pad: chrome)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Button(action: chrome.toggleSidebar) {
                        Image(systemName: "sidebar.left").font(.system(size: 17, weight: .medium))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .hoverEffect(.highlight)
                    .accessibilityLabel(chrome.sidebarShown ? "Hide Sidebar" : "Show Sidebar")
                    Spacer()
                }
                .padding(.horizontal, 8)
                Spacer()
                Text(library.photos.isEmpty ? "No photos in this folder." : "No photo selected.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .background(Color(.systemBackground))
        }
    }
}

/// What the editor needs to know when it's the iPad's right pane: no close button, a sidebar button instead.
struct PadChrome {
    var sidebarShown: Bool
    var toggleSidebar: () -> Void
}

/// The sidebar: filter tabs, a List | Grid switch, then the photos. The list order is frozen per tab (like the
/// Mac), so deciding a photo doesn't make it jump; it's refreshed when the tab changes.
struct PadSidebar: View {
    @Environment(Library.self) private var library
    @Binding var grid: Bool
    @State private var exporter = Exporter()
    @State private var confirmReplace = false
    @State private var picking = false

    private static let tile: CGFloat = 96

    var body: some View {
        @Bindable var library = library
        let items = library.navigation.compactMap(library.photo)
        VStack(spacing: 0) {
            FilterTabs(tab: $library.filter, inset: 16)
            HStack(spacing: 12) {
                Text(subtitle)
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 0)
                Picker("View", selection: $grid) {
                    Image(systemName: "list.bullet").accessibilityLabel("List").tag(false)
                    Image(systemName: "square.grid.2x2").accessibilityLabel("Grid").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            if items.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        if grid { gridView(items) } else { listView(items) }
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: library.openedID) { _, id in
                        // Follow keyboard moves and swipes in the editor.
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                    .onAppear { if let id = library.openedID { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
        .navigationTitle(library.folder?.lastPathComponent ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FolderMenu(tab: $library.filter, exporter: exporter, confirmReplace: $confirmReplace, picking: $picking)
            }
        }
        .folderPicker(isPresented: $picking)
        .confirmationDialog("Replace the original files with the leveled versions?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace \(library.savable(library.toExport.map(\.id)).count) originals") {
                Task { await library.saveToOriginalsWithToast(library.toExport.map(\.id)) }
            }
        } message: {
            Text("The untouched files are kept in a hidden backup folder, so you can restore any of them. RAW files stay as shot.")
        }
        .onChange(of: library.filter, initial: true) { refresh() }
        .onChange(of: library.folder) { refresh() }
        .onChange(of: library.photos.count) { refresh() }
        .onChange(of: library.reviewOrder) { refresh(keep: true) }
        // Nothing left to review once the check finishes: show everything instead of an empty page.
        .onChange(of: library.isAnalyzing) { _, busy in
            guard !busy, library.filter == .review else { return }
            if library.photos(for: .review).isEmpty { library.filter = .all } else { refresh(keep: true) }
        }
        .onAppear {
            if !library.isAnalyzing, library.filter == .review, library.photos(for: .review).isEmpty { library.filter = .all }
            library.gridActive = grid
        }
        .onChange(of: grid) { _, g in library.gridActive = g }
        .onDisappear { library.gridActive = false }
    }

    private func refresh(keep: Bool = false) {
        library.navigation = library.visible.map(\.id)
        if keep, let id = library.openedID, library.navigation.contains(id) { return }
        if library.openedID == nil || !library.navigation.contains(library.openedID!) {
            library.openedID = library.navigation.first
            library.selection = library.openedID.map { [$0] } ?? []
        }
    }

    private func select(_ p: Photo) {
        library.openedID = p.id
        library.selection = [p.id]
    }

    private var subtitle: String {
        if exporter.running { return "Exporting \(exporter.done) of \(exporter.total)…" }
        if let message = exporter.message { return message }
        let n = library.photos.count
        if library.isAnalyzing { return "\(n) photos · checking \(library.analyzedCount) of \(n)" }
        if library.filter == .crops { return "\(library.count(.crops)) with crop versions" }
        return "\(n) photos"
    }

    private var emptyText: String {
        switch library.filter {
        case .review: return library.isAnalyzing ? "Looking for horizons…" : "Nothing looks tilted."
        case .leveled: return "Nothing edited yet."
        case .kept: return "Nothing kept as shot."
        case .favorites: return "No favorites yet. Press F or tap ♡ on a photo."
        case .all: return "No photos in this folder."
        case .crops: return "No photo has two crop versions yet."
        }
    }

    // MARK: List

    private func listView(_ items: [Photo]) -> some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(library.sections(items, filter: library.filter)) { section in
                if let title = section.title { header(title) }
                ForEach(section.photos) { p in
                    PadRow(photo: p, selected: library.openedID == p.id)
                        .id(p.id)
                        .onTapGesture { select(p) }
                        .modifier(PhotoInteractions(photo: p))
                }
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 12)
    }

    // MARK: Grid

    private func gridView(_ items: [Photo]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tile), spacing: 2)], spacing: 2) {
            ForEach(library.sections(items, filter: library.filter)) { section in
                Section {
                    ForEach(section.photos) { p in
                        Cell(photo: p, showMark: library.filter == .all || library.filter == .review, suggested: library.hasSuggestion(p))
                            .overlay {
                                if library.openedID == p.id {
                                    Rectangle().strokeBorder(Color.primary, lineWidth: 3)
                                        .overlay(Rectangle().strokeBorder(Color(.systemBackground), lineWidth: 1).padding(3))
                                        .allowsHitTesting(false)
                                }
                            }
                            .id(p.id)
                            .onTapGesture { select(p) }
                            .hoverEffect(.highlight)
                            .modifier(PhotoInteractions(photo: p))
                    }
                } header: {
                    if let title = section.title { header(title) }
                }
            }
        }
        .padding(.horizontal, 2).padding(.bottom, 12)
        // ↑↓ move by a row: as many columns as the adaptive grid fits.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            library.gridColumns = max(1, Int((w - 4 + 2) / (Self.tile + 2)))
        }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.medium)).tracking(0.5).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 6)
    }
}

/// Right-click / long-press menu (same as the iPhone grid) and dragging the file out to other apps.
private struct PhotoInteractions: ViewModifier {
    @Environment(Library.self) private var library
    let photo: Photo

    func body(content: Content) -> some View {
        content
            .contextMenu {
                PhotoContextMenu(photo: photo)
            } preview: {
                Peek(photo: photo, note: library.note(for: photo))
            }
            .onDrag {
                // The original file (other apps get the photo as shot; Copy gives the leveled one).
                NSItemProvider(contentsOf: photo.url) ?? NSItemProvider()
            }
    }
}

/// A list row like the Mac's: thumbnail, name (+ RAW, ♥), status, camera line.
private struct PadRow: View {
    @Environment(Library.self) private var library
    let photo: Photo
    let selected: Bool
    @State private var image: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            Color.primary.opacity(0.05)
                .frame(width: 60, height: 44)
                .overlay {
                    if let image {
                        Color.clear
                            .aspectRatio(Geometry.finalAspect(CGFloat(image.width) / CGFloat(image.height), crop: photo.appliedCrop), contentMode: .fill)
                            .overlay { EditedImage(image: image, rotation: photo.appliedCorrection, crop: photo.appliedCrop, fix: photo.bandFixSource) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(photo.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                    if let tag = photo.companionTag {
                        Text(tag).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Ink.rule, lineWidth: 1))
                    }
                    if photo.favorite {
                        Image(systemName: "heart.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.red)
                    }
                }
                Text(library.note(for: photo)).font(.caption)
                    .foregroundStyle(photo.decision == .undecided ? .secondary : .primary)
                    .lineLimit(1)
                // A blank line until the header is read, so rows don't jump.
                Text(photo.info?.summaryLine ?? " ").font(.caption2).monospacedDigit()
                    .foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 8))
        .hoverEffect(.highlight)
        .contentShape(Rectangle())
        .task(id: photo.url) {
            if image == nil { image = await ImageCache.shared.image(for: photo.url, rawCompanion: photo.rawCompanion, maxPixel: 160) }
            await library.fillInfo(photo)
        }
    }
}
