import SwiftUI

struct GridScreen: View {
    @Environment(Library.self) private var library
    let zoom: Namespace.ID
    @State private var tab: Filter = .review
    @State private var picking = false
    @State private var exporter = Exporter()
    @State private var confirmReplace = false
    /// "Select" mode: tap toggles tiles; the bottom bar acts on them.
    @State private var selecting = false
    @State private var picked: Set<String> = []
    /// Settings ▸ Advanced ▸ "Film scan fixes" (hidden feature).
    @AppStorage(Library.labFixesKey) private var labFixes = false

    private func photos(_ t: Filter) -> [Photo] { library.photos(for: t) }

    var body: some View {
        let items = photos(tab)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                titleBlock
                tabs
                if items.isEmpty {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)], spacing: 2) {
                        ForEach(library.sections(items, filter: tab)) { section in
                        Section {
                        ForEach(section.photos) { p in
                            Cell(photo: p, showMark: tab == .all || tab == .review, suggested: library.hasSuggestion(p),
                                 checked: selecting ? picked.contains(p.id) : nil)
                                .zoomSource(p.id, in: zoom)
                                .onTapGesture {
                                    if selecting {
                                        if picked.contains(p.id) { picked.remove(p.id) } else { picked.insert(p.id) }
                                    } else { open(p, in: items) }
                                }
                                .contextMenu {
                                    Button { library.decide([p.id], .level) } label: { Label("Level", systemImage: "level") }
                                    Button { library.decide([p.id], .keep) } label: { Label("Keep as shot", systemImage: "hand.raised") }
                                    Button { library.decide([p.id], .undecided) } label: { Label("Undecided", systemImage: "circle.dashed") }
                                    Button { library.toggleFavorite([p.id]) } label: {
                                        Label(p.favorite ? "Unfavorite" : "Favorite", systemImage: p.favorite ? "heart.slash" : "heart")
                                    }
                                    Divider()
                                    Button { library.copyPhotos([p], kind: .asShown) } label: { Label("Copy", systemImage: "doc.on.doc") }
                                    Button { library.addToPhotos([p.id]) } label: { Label("Add to Photos", systemImage: "photo.badge.plus") }
                                    if p.rawCompanion != nil {
                                        Button { library.copyPhotos([p], kind: .raw) } label: { Label("Copy RAW File", systemImage: "doc.on.doc.fill") }
                                    }
                                    if !library.savable([p.id]).isEmpty {
                                        Button { Task { await saveOriginals([p.id]) } } label: {
                                            Label("Save to Original", systemImage: "square.and.arrow.down")
                                        }
                                    }
                                    if library.hasBackup(p) {
                                        Button { library.restoreOriginals([p.id]) } label: {
                                            Label("Restore Original", systemImage: "clock.arrow.circlepath")
                                        }
                                    }
                                    Button(role: .destructive) { library.resetToOriginal([p.id]) } label: {
                                        Label("Reset Decision", systemImage: "arrow.counterclockwise")
                                    }
                                    if labFixes {
                                        Menu {
                                            Button { library.applyBandFix([p.id]) } label: {
                                                Label("Remove Shutter Bands", systemImage: "wand.and.rays")
                                            }
                                            if p.bandFix != nil {
                                                Button { library.removeBandFix([p.id]) } label: {
                                                    Label("Remove Fix", systemImage: "xmark.circle")
                                                }
                                            }
                                        } label: { Label("Fixes", systemImage: "wand.and.rays") }
                                    }
                                    Divider()
                                    Button(role: .destructive) { library.requestDelete([p.id]) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                } preview: {
                                    // The iPhone counterpart of the Mac's floating quick look.
                                    Peek(photo: p, note: library.note(for: p))
                                }
                        }
                        } header: {
                            if let title = section.title {
                                Text(title.uppercased())
                                    .font(.caption.weight(.medium)).tracking(0.5).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 6)
                            }
                        }
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) { if selecting { selectBar } }
        .deleteConfirmation(active: library.openedID == nil)
        // Deleted (or otherwise gone) photos leave the selection.
        .onChange(of: library.photos.count) {
            let ids = Set(library.photos.map(\.id))
            picked.formIntersection(ids)
        }
        .folderPicker(isPresented: $picking)
        // ⋯ ▸ History (the editor shows its own while it's open).
        .sheet(isPresented: Binding(get: { library.showActivity && library.openedID == nil },
                                    set: { if !$0 { library.showActivity = false } })) {
            ActivityView().environment(library)
        }
        .confirmationDialog("Replace the original files with the leveled versions?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace \(library.savable(library.toExport.map(\.id)).count) originals") {
                Task { await saveOriginals(library.toExport.map(\.id)) }
            }
        } message: {
            Text("The untouched files are kept in a hidden backup folder, so you can restore any of them. RAW files stay as shot.")
        }
        // Nothing left to review once analysis finishes: show everything instead of an empty page.
        .onChange(of: library.isAnalyzing) { _, analyzing in
            if !analyzing, tab == .review, photos(.review).isEmpty { tab = .all }
        }
        .onAppear {
            if !library.isAnalyzing, photos(.review).isEmpty { tab = .all }
        }
    }

    private var emptyText: String {
        if library.isAnalyzing && tab == .review { return "Looking for horizons…" }
        switch tab {
        case .review: return "Nothing looks tilted."
        case .leveled: return "Nothing edited yet."
        case .kept: return "Nothing kept as shot."
        case .favorites: return "No favorites yet. Tap ♡ on a photo."
        case .all: return "No photos in this folder."
        case .crops: return "No photo has two crop versions yet. In crop mode, + Version saves one."
        }
    }

    // MARK: Title, like a Notion page

    private var titleBlock: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(library.folder?.lastPathComponent ?? "")
                    .font(.system(size: 30, weight: .bold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            Button(selecting ? "Done" : "Select") {
                withAnimation(.easeOut(duration: 0.15)) { selecting.toggle(); picked = [] }
            }
            .font(.body.weight(selecting ? .semibold : .regular))
            .frame(height: 44)
            menu
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    private var subtitle: String {
        if exporter.running { return "Exporting \(exporter.done) of \(exporter.total)…" }
        if let message = exporter.message { return message }
        let n = library.photos.count
        if selecting { return picked.isEmpty ? "Tap photos to select" : "\(picked.count) selected" }
        if library.isAnalyzing { return "\(n) photos · checking \(library.analyzedCount) of \(n)" }
        if tab == .crops { return "\(library.count(.crops)) of \(n) photos · with crop versions" }
        return "\(n) photos"
    }

    private var menu: some View {
        Menu {
            Button { library.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!library.canUndo)
            Button { library.showActivity = true } label: { Label("History", systemImage: "clock.arrow.circlepath") }
            Button { library.applyAutoApprove() } label: {
                Label("Apply all suggestions", systemImage: "wand.and.stars")
            }
            // A collection, not a tab: photos with two or more crop versions. Any tab leaves it.
            Button { withAnimation(.easeOut(duration: 0.15)) { tab = .crops } } label: {
                Label("Photos with crop versions (\(library.count(.crops)))", systemImage: "crop")
            }
            Divider()
            Button { exporter.run(library) } label: {
                Label("Export \(library.toExport.count) leveled", systemImage: "square.and.arrow.up")
            }
            .disabled(library.toExport.isEmpty || exporter.running)
            Button { confirmReplace = true } label: {
                Label("Replace \(library.savable(library.toExport.map(\.id)).count) originals…", systemImage: "square.and.arrow.down")
            }
            .disabled(library.savable(library.toExport.map(\.id)).isEmpty || exporter.running)
            Menu {
                let favorites = library.photos.filter(\.favorite).map(\.id)
                Button { library.addToPhotos(favorites) } label: { Label("Add \(favorites.count) favorites", systemImage: "heart") }
                    .disabled(favorites.isEmpty)
                Button { library.addToPhotos(library.photos.map(\.id)) } label: {
                    Label("Add all \(library.photos.count)", systemImage: "photo.stack")
                }
                Button { library.syncFavoritesToPhotos() } label: { Label("Mark favorites in Photos", systemImage: "heart.circle") }
                    .disabled(favorites.isEmpty)
            } label: { Label("Apple Photos", systemImage: "photo.on.rectangle") }
            SwitchFolderMenu()
            Button { picking = true } label: { Label("Open another folder", systemImage: "folder") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }

    // MARK: Tabs: plain words, the current one in full ink

    private var tabs: some View {
        VStack(spacing: 0) {
            // Labels never wrap; with big counts the row scrolls sideways instead.
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(Filter.allCases) { t in
                    Button { withAnimation(.easeOut(duration: 0.15)) { tab = t } } label: {
                        HStack(spacing: 5) {
                            // A heart instead of the word keeps the row short.
                            if t == .favorites {
                                Image(systemName: tab == t ? "heart.fill" : "heart").accessibilityLabel(t.label)
                            } else {
                                Text(t.label)
                            }
                            Text("\(library.count(t))").foregroundStyle(.tertiary).monospacedDigit()
                        }
                        .lineLimit(1)
                        .fixedSize()
                        .font(.subheadline.weight(tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? .primary : .secondary)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(tab == t ? Color.primary : .clear).frame(height: 1.5)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            }
            Rectangle().fill(Ink.rule).frame(height: Ink.hairline)
        }
        .padding(.bottom, 2)
    }

    /// Select mode's bottom bar: Favorite / Level / Delete / Done for the picked photos.
    private var selectBar: some View {
        let ids = library.photos.map(\.id).filter(picked.contains)
        return HStack(spacing: 0) {
            barButton("heart", "Favorite") { library.toggleFavorite(ids) }
            barButton("level", "Level") { library.decide(ids, .level) }
            barButton("trash", "Delete") { library.requestDelete(ids) }
            if labFixes {
                Menu {
                    Button { library.applyBandFix(ids) } label: { Label("Fix bands", systemImage: "wand.and.rays") }
                    Button { library.removeBandFix(ids) } label: { Label("Remove Fix", systemImage: "xmark.circle") }
                        .disabled(!ids.contains { library.photo($0)?.bandFix != nil })
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "ellipsis.circle").font(.system(size: 17, weight: .medium))
                        Text("More").font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .disabled(picked.isEmpty)
            }
            Button { withAnimation(.easeOut(duration: 0.15)) { selecting = false; picked = [] } } label: {
                Text("Done").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
            }
        }
        .padding(.horizontal, 8)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Ink.rule).frame(height: Ink.hairline) }
    }

    private func barButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                Text(label).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .disabled(picked.isEmpty)
    }

    private func saveOriginals(_ ids: [String]) async {
        let r = await library.saveToOriginals(ids)
        library.toast = r.failed.isEmpty ? (r.saved == 1 ? "Saved to original" : "Saved \(r.saved) originals") : "Saved \(r.saved), \(r.failed.count) failed"
    }

    private func open(_ p: Photo, in items: [Photo]) {
        library.filter = tab
        library.navigation = items.map(\.id)
        library.openedID = p.id
    }
}

/// A square thumbnail showing the photo as it will be exported.
private struct Cell: View {
    @Environment(Library.self) private var library
    let photo: Photo
    let showMark: Bool
    var suggested = false
    /// Select mode: nil when not selecting, else whether this tile is picked.
    var checked: Bool? = nil
    @AppStorage("ios.thumbFill") private var thumbFill = true
    @State private var image: CGImage?

    var body: some View {
        Color.primary.opacity(0.05)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    // As it will be saved (rotation + crop), cropped to the square or fitted whole.
                    Color.clear
                        .aspectRatio(Geometry.finalAspect(CGFloat(image.width) / CGFloat(image.height), crop: photo.appliedCrop),
                                     contentMode: thumbFill ? .fill : .fit)
                        .overlay { EditedImage(image: image, rotation: photo.appliedCorrection, crop: photo.appliedCrop, fix: photo.bandFixSource) }
                        .clipped()
                }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if let tag = library.tag(for: photo) {
                    let filled = tag.kind == .leveled
                    Text(tag.text)
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(filled ? Color.black : .white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(filled ? Color.white : Color.black.opacity(0.5), in: Capsule())
                        .padding(5)
                }
            }
            .overlay(alignment: .topLeading) {
                if let tag = photo.companionTag {
                    Text(tag)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if photo.favorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .padding(5)
                }
            }
            .overlay {
                if checked == true { Color.white.opacity(0.25).allowsHitTesting(false) }
            }
            .overlay(alignment: .bottomTrailing) {
                if let checked {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .medium))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(checked ? Color.black : .white, checked ? Color.white : .clear)
                        .shadow(color: .black.opacity(0.45), radius: 2)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .task(id: photo.url) {
                if image == nil {
                    image = await ImageCache.shared.image(for: photo.url, rawCompanion: photo.rawCompanion, maxPixel: 160)
                }
                if let sharp = await ImageCache.shared.image(for: photo.url, rawCompanion: photo.rawCompanion, maxPixel: 420) {
                    image = sharp
                }
                await library.fillInfo(photo)   // camera details for the peek and editor (header only, after the picture)
            }
    }
}

/// Writes leveled copies into "<folder>/leveled", keeping metadata.
@MainActor
@Observable
final class Exporter {
    var running = false
    var done = 0
    var total = 0
    var message: String?

    func run(_ library: Library) {
        guard let folder = library.folder else { return }
        let jobs = library.toExport.map { (id: $0.id, url: $0.url, degrees: $0.appliedCorrection, crop: $0.appliedCrop, band: $0.bandFix) }
        let dest = folder.appendingPathComponent("leveled", isDirectory: true)
        running = true; done = 0; total = jobs.count; message = nil
        Task {
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dest.appendingPathComponent(ImageLoader.exportMarker).path, contents: nil)
            var failed = 0, exported: [String] = []
            for job in jobs {
                let out = dest.appendingPathComponent(job.id).deletingPathExtension().appendingPathExtension("jpg")
                let ok = await Task.detached(priority: .userInitiated) {
                    (try? Renderer.export(source: job.url, degrees: job.degrees, crop: job.crop, bandFix: job.band,
                                          to: out, format: .jpeg, quality: 0.95)) != nil
                }.value
                if !ok { failed += 1 } else { exported.append(job.id) }
                done += 1
            }
            library.noteExport(exported, to: dest)
            running = false
            message = failed == 0 ? "Saved \(done) photos to “leveled”" : "Saved \(done - failed), \(failed) failed"
        }
    }
}

/// Floating preview shown on long-press: the photo as it will be, with its status.
private struct Peek: View {
    let photo: Photo
    let note: String
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.primary.opacity(0.05)
                if let image {
                    Color.clear
                        .aspectRatio(Geometry.finalAspect(CGFloat(image.width) / CGFloat(image.height), crop: photo.appliedCrop), contentMode: .fill)
                        .overlay { EditedImage(image: image, rotation: photo.appliedCorrection, crop: photo.appliedCrop, fix: photo.bandFixSource) }
                }
            }
            .frame(width: 340, height: 227)
            .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(photo.name + (photo.companionTag.map { " + " + $0 } ?? "")).font(.subheadline.weight(.medium))
                Text(note).font(.footnote).foregroundStyle(.secondary)
                if let summary = photo.info?.summaryLine {
                    Text(summary).font(.footnote).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(12)
        }
        .frame(width: 340)
        .task { image = await ImageCache.shared.image(for: photo.url, rawCompanion: photo.rawCompanion, maxPixel: 1200) }
    }
}
