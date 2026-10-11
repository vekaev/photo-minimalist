import SwiftUI

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var library = library
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            Group {
                if library.folder == nil {
                    EmptyState()
                } else if let p = library.photo(library.openedID) {
                    PhotoView(photo: p)
                } else {
                    GridView()
                }
            }
            .background(Theme.ground)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { library.chooseFolder() } label: { Label("Open Folder", systemImage: "folder") }
                Button { library.showExport = true } label: {
                    Label("Export \(library.toExport.count)", systemImage: "square.and.arrow.up")
                }
                .disabled(library.toExport.isEmpty)
                .help("Render leveled copies of every photo marked Level")
            }
        }
        .navigationTitle(library.folder?.lastPathComponent ?? "Horizon Leveler")
        .navigationSubtitle(library.folder == nil ? "" : "\(library.photos.count) photos")
        .sheet(isPresented: $library.showExport) { ExportView() }
        // Give the photo the whole window while editing; bring the sidebar back in the grid.
        .onChange(of: library.openedID == nil) { _, inGrid in
            withAnimation { columns = inGrid ? .all : .detailOnly }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.hasDirectoryPath }) else { return false }
            library.open(url)
            return true
        }
    }
}

private struct EmptyState: View {
    @Environment(Library.self) private var library
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "level").font(.system(size: 48, weight: .light)).foregroundStyle(Theme.accent)
            Text("Drop a folder of photos here").font(.title2.weight(.semibold))
            Text("RAW, JPEG, HEIC and TIFF. Originals are never modified.").foregroundStyle(.secondary)
            Button("Open Folder…") { library.chooseFolder() }
                .controlSize(.large).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Sidebar: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        List(selection: Binding(get: { library.filter }, set: { if let s = $0 { library.filter = s; library.selection = [] } })) {
            Section("Photos") {
                ForEach(Status.allCases.filter { $0 != .pending || library.isAnalyzing }) { s in
                    HStack(spacing: 10) {
                        Circle().fill(Theme.color(for: s)).frame(width: 8, height: 8)
                        Text(s.label)
                        Spacer()
                        Text("\(library.count(s))").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(s)
                }
            }
            Section("Auto-level") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Level automatically when confidence ≥ \(Int(library.autoApproveConfidence * 100))%")
                        .font(.callout)
                    Slider(value: $library.autoApproveConfidence, in: 0.5...1.0, step: 0.01)
                    Text("Treat tilts under \(String(format: "%.1f°", library.minimumTilt)) as level").font(.callout)
                    Slider(value: $library.minimumTilt, in: 0...1, step: 0.1)
                    Button("Apply to Needs review") { library.applyAutoApprove() }
                        .help("Level every photo in Needs review that meets the confidence threshold. Undo with ⌘Z.")
                    Toggle("Next photo after L / K / U", isOn: $library.advanceAfterDecision)
                }
                .padding(.vertical, 4)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if library.isAnalyzing {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Analyzing \(library.analyzedCount) / \(library.photos.count)").font(.caption).monospacedDigit()
                    ProgressView(value: Double(library.analyzedCount), total: Double(max(library.photos.count, 1)))
                }
                .padding(12)
            }
        }
    }
}

struct GridView: View {
    @Environment(Library.self) private var library
    @FocusState private var focused: Bool
    @State private var columns = 4
    @State private var anchor: String?

    private let minCell: CGFloat = 210, spacing: CGFloat = 12, pad: CGFloat = 20

    var body: some View {
        let items = library.visible
        VStack(spacing: 0) {
            header(items)
            if items.isEmpty {
                Text(library.isAnalyzing ? "Analyzing…" : "Nothing here.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: minCell), spacing: spacing)], spacing: spacing) {
                                ForEach(items) { p in
                                    Thumbnail(photo: p, selected: library.selection.contains(p.id))
                                        .id(p.id)
                                        .onTapGesture(count: 2) { library.openPhoto(p.id) }
                                        .onTapGesture { click(p.id, items) }
                                }
                            }
                            .padding(pad)
                        }
                        .onChange(of: library.selection) { _, sel in
                            if sel.count == 1, let id = sel.first { withAnimation { proxy.scrollTo(id) } }
                        }
                    }
                    .onAppear { columns = columnCount(geo.size.width) }
                    .onChange(of: geo.size.width) { _, w in columns = columnCount(w) }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress { press in handle(press, items) }
    }

    private func header(_ items: [Photo]) -> some View {
        HStack(spacing: 14) {
            Text(library.filter.label).font(.title2.weight(.semibold))
            Text("\(items.count)").foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            HStack(spacing: 10) {
                Keycap(key: "L"); Text("Level")
                Keycap(key: "K"); Text("Keep as shot")
                Keycap(key: "U"); Text("Undecided")
                Keycap(key: "↵"); Text("Open")
                Keycap(key: "⌘Z"); Text("Undo")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, pad).padding(.vertical, 14)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private func columnCount(_ width: CGFloat) -> Int {
        max(1, Int((width - pad * 2 + spacing) / (minCell + spacing)))
    }

    private func click(_ id: String, _ items: [Photo]) {
        focused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { toggle(id) }
        else if flags.contains(.shift) { extend(to: id, in: items) }
        else { library.selection = [id]; anchor = id }
    }

    private func toggle(_ id: String) {
        if library.selection.contains(id) { library.selection.remove(id) } else { library.selection.insert(id) }
        anchor = id
    }

    private func extend(to id: String, in items: [Photo]) {
        guard let a = anchor, let i = items.firstIndex(where: { $0.id == a }), let j = items.firstIndex(where: { $0.id == id }) else {
            library.selection = [id]; anchor = id; return
        }
        library.selection = Set(items[min(i, j)...max(i, j)].map(\.id))
    }

    private func handle(_ press: KeyPress, _ items: [Photo]) -> KeyPress.Result {
        let ids = items.map(\.id)
        let current = ids.firstIndex { library.selection.contains($0) }
        func move(_ delta: Int) -> KeyPress.Result {
            guard !ids.isEmpty else { return .handled }
            let i = min(max((current ?? -delta.signum()) + delta, 0), ids.count - 1)
            library.selection = [ids[i]]; anchor = ids[i]
            return .handled
        }
        func decide(_ d: Decision) -> KeyPress.Result {
            let chosen = ids.filter { library.selection.contains($0) }
            guard !chosen.isEmpty else { return .handled }
            // Keep the cursor where it was: on the first photo after the ones that just left this list.
            let after = ids.drop(while: { $0 != chosen.last! }).dropFirst().first { !library.selection.contains($0) }
            library.decide(chosen, d)
            let stillHere = Set(library.visible.map(\.id))
            if chosen.allSatisfy({ !stillHere.contains($0) }) {
                library.selection = after.map { [$0] } ?? []
            }
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
            if let i = current { library.openPhoto(ids[i]) }
            return .handled
        case .escape:
            library.selection = []
            return .handled
        default: break
        }
        switch press.characters.lowercased() {
        case "l": return decide(.level)
        case "k": return decide(.keep)
        case "u": return decide(.undecided)
        default: return .ignored
        }
    }
}

private struct Thumbnail: View {
    @Environment(Library.self) private var library
    let photo: Photo
    let selected: Bool
    @State private var image: CGImage?

    var body: some View {
        let status = library.status(of: photo)
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Theme.ground
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFit()
                        .rotationEffect(.degrees(-photo.appliedCorrection))
                        // Zoom in so the preview matches the exported crop: no empty corners.
                        .scaleEffect(1 / Geometry.cropScale(width: CGFloat(image.width), height: CGFloat(image.height),
                                                            degrees: photo.appliedCorrection))
                        .overlay {
                            if let d = photo.detection, photo.decision != .keep {
                                HorizonLine(degrees: d.angle + photo.appliedCorrection)
                            }
                        }
                }
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                if let d = photo.detection {
                    Text(Geometry.format(d.angle))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if status == .keep || status == .level {
                    Text(status == .keep ? "Kept" : Geometry.format(photo.correction))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.color(for: status), in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }
            HStack {
                Text(photo.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let d = photo.detection {
                    Text("\(Int(d.confidence * 100))%").monospacedDigit()
                        .foregroundStyle(d.confidence < 0.6 ? Theme.accent : .secondary)
                }
            }
            .font(.callout)
        }
        .padding(8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Theme.accent : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .task(id: photo.url) { image = await ImageCache.shared.image(for: photo.url, maxPixel: 420) }
    }
}

/// Dashed line through the center at `degrees` (counter-clockwise positive).
struct HorizonLine: View {
    let degrees: Double
    var body: some View {
        GeometryReader { geo in
            let r = degrees * .pi / 180
            let len = hypot(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let dx = cos(r) * len / 2, dy = -sin(r) * len / 2
            Path { p in
                p.move(to: CGPoint(x: c.x - dx, y: c.y - dy))
                p.addLine(to: CGPoint(x: c.x + dx, y: c.y + dy))
            }
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .allowsHitTesting(false)
    }
}
