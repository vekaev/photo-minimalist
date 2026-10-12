import AppKit
import SwiftUI

enum CompareMode: String, CaseIterable, Identifiable {
    case off, overlay, sideBySide, split
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .overlay: return "Overlay"
        case .sideBySide: return "Side by side"
        case .split: return "Split"
        }
    }
}

/// The large preview on the right: by default just the photo. A confident tilt shows as a small corner chip
/// ("Tilted 1.4° · Level"); everything else about leveling lives in the level tool (R), like crop (C).
/// Nothing is applied until you press L (or Level).
struct PhotoView: View {
    @Environment(Library.self) private var library
    let photo: Photo
    /// Shown as the floating quick-look card.
    var floating = false

    @AppStorage("gridMode") private var gridMode: GridMode = .fine
    @AppStorage("horizontalOnly") private var horizontalOnly = true
    @AppStorage("showSuggestion") private var showDetected = true
    @AppStorage("showGuide") private var showGuide = true
    @AppStorage("showLoupes") private var showLoupes = true
    @AppStorage("compareMode") private var compare: CompareMode = .off
    @AppStorage("overlayOpacity") private var overlayOpacity = 0.5

    @State private var image: CGImage?

    init(photo: Photo, floating: Bool = false) {
        self.photo = photo
        self.floating = floating
        // Open with the picture that's already loaded (no blank first frame), then sharpen.
        _image = State(initialValue: ImageCache.shared.cached(for: photo.url))
    }
    @State private var showOriginal = false
    @State private var preview: Double?
    /// Hovering a side of the As shot | Level switch shows that result before deciding.
    @State private var peek: Double?
    @State private var pick = LinePick()
    @State private var pickFrame: CGRect = .infinite
    // Crop mode
    @State private var cropMode = false
    @State private var cropDraft = CropMath.full
    @AppStorage("cropRatio") private var cropRatio: CropRatio = .original
    @State private var cropPortrait = false
    @State private var guideY: CGFloat = 0.5
    /// The dashed suggested horizon, dragged up or down (fraction of the photo's height). Reset per photo.
    @State private var lineShift: CGFloat = 0
    @State private var lineDragStart: CGFloat?
    /// Crop studio: all versions side by side (⇧C).
    @State private var showStudio = false
    @State private var splitX: CGFloat = 0.5
    @State private var showHistory = false
    /// The pointer is on the corner chip: preview the leveled photo and show the suggested line.
    @State private var chipHover = false
    /// The info card (I) over the photo, bottom-left; stays on from photo to photo.
    @AppStorage("showInfo") private var showInfo = false
    @FocusState private var focused: Bool

    /// The level tool is open (it stays open from photo to photo until Done / Esc).
    private var levelMode: Bool { library.levelTool && !cropMode && !fixesMode }

    /// Settings ▸ Advanced ▸ "Film scan fixes": the Fixes mode and its menu items exist only while it's on.
    @AppStorage(Library.labFixesKey) private var labFixes = false
    /// The Fixes panel is open (stays open from photo to photo until Done / Esc). Not in quick look.
    private var fixesMode: Bool { labFixes && library.fixesTool && !cropMode && !floating }

    /// Rotation currently on screen (counter-clockwise positive).
    private var shown: Double {
        if showOriginal { return 0 }
        if let preview { return preview }
        if let peek { return peek }
        return photo.appliedCorrection
    }

    var body: some View {
        VStack(spacing: 0) {
            topRow
            if fixesMode {
                FixesWorkspace(photo: photo, image: image)
            } else {
            Group {
                if compare == .sideBySide && !showOriginal {
                    HStack(spacing: 10) {
                        pane(rotation: 0, interactive: false, caption: "Before")
                        pane(rotation: shown, interactive: true, caption: "After")
                    }
                } else {
                    pane(rotation: shown, interactive: true, caption: nil)
                }
            }
            .padding(.horizontal, 20)
            .overlay(alignment: .bottomLeading) {
                if showInfo && !cropMode { InfoOverlay(photo: photo).padding(.leading, 20).allowsHitTesting(false) }
            }
            if cropMode {
                CropVersionStrip(photo: photo, image: image, draft: cropDraft,
                                 onAdd: addVersion, onLoad: loadVersion, onCompare: { showStudio = true })
                    .padding(.horizontal, 20).padding(.top, 10)
                cropBar
            } else if levelMode { bottom }
            }
        }
        .background(Theme.ground)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onChange(of: photo.id) { pick.clear(); preview = nil; peek = nil; chipHover = false; showOriginal = false; cropMode = false; lineShift = 0; showStudio = false; focused = true }
        .onChange(of: library.levelTool) { if !library.levelTool { pick.clear(); preview = nil; peek = nil } }
        .onChange(of: library.fixesTool) { if library.fixesTool { pick.clear(); peek = nil; chipHover = false; showOriginal = false; if cropMode { cancelCrop() } } }
        .sheet(isPresented: $showStudio) {
            CropStudio(photo: photo, image: image, onChoose: { v in
                library.chooseCropVersion(photo.id, v.id)
                showStudio = false
                withAnimation(.easeOut(duration: 0.15)) { cropMode = false }
            }, onClose: { showStudio = false })
        }
        .onChange(of: image?.width) { if let image { photo.analysisAspect = CGFloat(image.width) / CGFloat(image.height) } }
        .onKeyPress(phases: [.down, .repeat, .up]) { handle($0) }
        .task(id: photo.url) {
            if image == nil || (image?.width ?? 0) < 400 {
                image = await ImageCache.shared.image(for: photo.url, rawCompanion: photo.rawCompanion, maxPixel: 420) ?? image
            }
            if let sharp = await ImageCache.shared.image(for: photo.url, rawCompanion: photo.rawCompanion, maxPixel: 3000) {
                image = sharp
            }
        }
    }

    // MARK: Top row: name, position, status, then the customizable control bar

    @AppStorage(PhotoControl.macKey) private var controlsRaw = PhotoControl.defaultValue(.mac)
    @AppStorage(PhotoControl.macLabelsKey) private var controlLabels = false
    /// Width left for the control bar (measured), so extra controls go into the "»" menu instead of wrapping.
    @State private var barWidth: CGFloat = 0

    private var controls: [PhotoControl] { PhotoControl.parse(controlsRaw, on: .mac) }

    private var topRow: some View {
        let position = (library.navigation.firstIndex(of: photo.id) ?? 0) + 1
        return HStack(spacing: 10) {
            // The name and status get their room first; the bar takes what's left.
            HStack(spacing: 10) {
                Text(photo.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text("\(position) / \(library.navigation.count)").font(.callout).foregroundStyle(.tertiary).monospacedDigit()
                    .lineLimit(1).fixedSize()
                // Decided photos say so quietly: "Leveled −1.3°", "Cropped 4:5", "Kept as shot".
                if photo.decision != .undecided {
                    Text(library.note(for: photo)).font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
            .layoutPriority(1)
            controlBar
            if floating {
                Button { library.quickLook = false } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close (Space or Esc)")
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .contextMenu {
            Button("Customize Controls…") { library.showControls = true }
            Toggle("Show Labels", isOn: $controlLabels)
            if labFixes, !floating {
                Divider()
                Button(fixesMode ? "Close Fixes" : "Fixes…") { toggleFixes() }
            }
        }
    }

    /// The chosen controls, in order, trailing; whatever doesn't fit goes into a trailing "»" menu.
    private var controlBar: some View {
        let all = controls
        let spacing: Double = controlLabels ? 4 : 10
        let shown = barWidth == 0 ? all.count : PhotoControl.fitting(all.map { ControlLabel.width($0.shortTitle, labels: controlLabels) },
                                         in: Double(barWidth), spacing: spacing, overflowWidth: 28)
        return Color.clear
            .frame(minWidth: 28, maxWidth: .infinity, minHeight: 28, maxHeight: 28)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
            .overlay(alignment: .trailing) {
                HStack(spacing: spacing) {
                    ForEach(all.prefix(shown)) { controlButton($0) }
                    if shown < all.count { overflowMenu(Array(all.dropFirst(shown))) }
                }
                .fixedSize()
            }
    }

    private func controlButton(_ c: PhotoControl) -> some View {
        Button { perform(c) } label: {
            ControlLabel(symbol: symbol(c), title: c.shortTitle, labels: controlLabels)
                .foregroundStyle(style(c))
        }
        .buttonStyle(.plain)
        .disabled(!enabled(c))
        .help(help(c))
        .popover(isPresented: c == .history ? $showHistory : .constant(false), arrowEdge: .bottom) {
            history.padding(14).frame(width: 300)
        }
    }

    private func overflowMenu(_ rest: [PhotoControl]) -> some View {
        Menu {
            ForEach(rest) { c in
                Button { perform(c, fromMenu: true) } label: { Label(c.title, systemImage: symbol(c)) }
                    .disabled(!enabled(c))
            }
            Divider()
            if labFixes, !controls.contains(.fixes), !floating {
                Button("Fixes…") { toggleFixes() }
            }
            Button("Customize Controls…") { library.showControls = true }
        } label: {
            Image(systemName: "chevron.right.2").frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("More controls")
    }

    /// What a control does: the same functions as its keyboard shortcut and menu command.
    private func perform(_ c: PhotoControl, fromMenu: Bool = false) {
        let ids = library.targets(for: photo.id)
        switch c {
        case .level: toggleLevelTool()
        case .crop: cropMode ? cancelCrop() : startCrop()
        case .favorite: library.toggleFavorite(ids)
        case .original: withAnimation(.easeOut(duration: 0.12)) { showOriginal.toggle() }
        case .info: showInfo.toggle()
        // From the "»" menu there's no button to hang the popover on: the folder history, this photo only.
        case .history: if fromMenu { library.showActivity = true } else { showHistory.toggle() }
        case .compare: compare = cycle(compare)
        case .copy: library.copyPhotos(ids.compactMap(library.photo), kind: .asShown)
        case .save: Task { await library.saveToOriginalsWithToast(ids) }
        case .export: library.showExport = true
        case .trash: library.requestDelete(ids)
        case .photos: library.addToPhotos(ids)
        case .undo: library.undo()
        case .viewOptions: withAnimation { library.showSettings.toggle() }
        case .fixes: toggleFixes()
        }
    }

    private func toggleFixes() {
        if fixesMode { library.fixesTool = false } else { library.openFixes(photo.id) }
    }

    private func enabled(_ c: PhotoControl) -> Bool {
        switch c {
        case .save: return !library.savable(library.targets(for: photo.id)).isEmpty
        case .export: return !library.toExport.isEmpty
        case .undo: return library.canUndo
        default: return true
        }
    }

    private func symbol(_ c: PhotoControl) -> String {
        switch c {
        case .favorite: return photo.favorite ? "heart.fill" : "heart"
        case .info: return showInfo ? "info.circle.fill" : "info.circle"
        case .original: return showOriginal ? "eye.fill" : "eye"
        default: return c.symbol
        }
    }

    /// Monochrome: secondary at rest, primary while on; the favorite heart stays red.
    private func style(_ c: PhotoControl) -> AnyShapeStyle {
        let on: Bool
        switch c {
        case .favorite: return photo.favorite ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)
        case .level: on = levelMode
        case .crop: on = cropMode
        case .info: on = showInfo
        case .original: on = showOriginal
        case .history: on = showHistory
        case .compare: on = compare != .off
        case .viewOptions: on = library.showSettings
        case .fixes: on = fixesMode
        default: on = false
        }
        return on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    private func help(_ c: PhotoControl) -> String {
        switch c {
        case .favorite: return photo.favorite ? "Unfavorite (F)" : "Favorite (F), also tags the file Red in Finder"
        case .compare: return "Compare: \(compare.label) (click for \(cycle(compare).label))"
        case .viewOptions: return "View options (S)"
        default: return c.title + (c.shortcut.map { " (\($0))" } ?? "")
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History").font(.headline)
            Text("Click a step to go back to it. Originals are never modified.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 2) {
                ForEach(Array(photo.history.enumerated()), id: \.offset) { i, step in
                    Button { library.jump(photo.id, to: i) } label: {
                        HStack {
                            Text(step.label)
                            Spacer()
                            Text(step.date, style: .time).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .foregroundStyle(i > photo.index ? .secondary : .primary)
                        .background(i == photo.index ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            Button("Show all activity…") { showHistory = false; library.showActivity = true }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("The folder's history, with Revert (⌘Y)")
        }
    }

    // MARK: Level tool: the headline, As shot | Leveled, the ruler

    private var headline: String {
        if let preview { return Geometry.format(preview) }
        if let peek { return peek == 0 ? "Preview · as shot" : "Preview · leveled " + Geometry.format(peek) }
        return library.note(for: photo)
    }

    private var bottom: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.system(size: 20, weight: .medium)).monospacedDigit()
                    Text(subline).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                DecisionSwitch(photo: photo, decide: { decide($0) }, peek: { peek = $0 })
                Button { closeLevelTool() } label: {
                    Text("Done").fontWeight(.semibold).padding(.horizontal, 16).frame(height: 30)
                        .foregroundStyle(Theme.ground).background(Color.primary, in: Capsule())
                }
                .help("Close the level tool (↵ or Esc)")
            }
            .buttonStyle(.plain)
            StraightenRuler(
                value: preview ?? (photo.decision == .level ? photo.correction : 0),
                onChange: { preview = $0 },
                onCommit: { v in library.setCorrection(photo.id, v); preview = nil }
            )
            Text("Click both ends of the horizon (hold to magnify, drag to fine-tune, ↵ to level) · [ ] ±0.1° · ⇧[ ⇧] ±1° · Space: original ⇄ result · ↵ / Esc done")
                .font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    private var subline: String {
        switch photo.decision {
        case .level: return "Showing the leveled photo · K shows it as shot · U clears the decision · adjust below"
        case .keep: return "Showing it as shot, unchanged · hover Level to preview · L levels it"
        case .undecided:
            if library.hasSuggestion(photo) { return "Showing it as shot · dashed line = suggested horizon · hover Level to preview, L applies it" }
            if photo.analyzed { return "Click both ends of the horizon to level it yourself." }
            if photo.detection == nil && photo.analyzed { return "Click both ends of the horizon to level it yourself." }
            return "Press K to keep it, or level it yourself below."
        }
    }

    // MARK: Canvas

    private func fitted(aspect: CGFloat, in size: CGSize) -> CGSize {
        let w = min(size.width, size.height * aspect)
        return CGSize(width: w, height: w / aspect)
    }

    private func centered(_ s: CGSize, in area: CGSize) -> CGRect {
        CGRect(x: (area.width - s.width) / 2, y: (area.height - s.height) / 2, width: s.width, height: s.height)
    }

    /// The photo at a rotation, centered in a canvas of `area`.
    /// The photo as it will be saved: rotated, then cropped to fill its frame, so there are never tilted
    /// edges or a dimmed background around it.
    /// - Parameter fixed: with the photo's film scan fix (off for "before" / original layers).
    private func photoLayer(_ fit: CGSize, rotation: Double, area: CGSize, crop: CGRect? = nil, fixed: Bool = true) -> some View {
        ZStack {
            if let image { EditedImage(image: image, rotation: rotation, crop: crop, fix: fixed && !showOriginal ? photo.bandFixSource : nil) }
        }
        .frame(width: fit.width, height: fit.height)
        .frame(width: area.width, height: area.height)
    }

    /// The crop shown in the main pane: the saved crop, except while editing the crop or viewing the original.
    private var displayCrop: CGRect? { cropMode || showOriginal ? nil : photo.appliedCrop }

    private var imageAspect: CGFloat { image.map { CGFloat($0.width) / CGFloat($0.height) } ?? 1.5 }

    private func pane(rotation: Double, interactive: Bool, caption: String?) -> some View {
        GeometryReader { geo in
            let area = geo.size
            let crop = interactive ? displayCrop : nil
            let fit = fitted(aspect: Geometry.finalAspect(imageAspect, crop: crop), in: area)
            let originalFit = fitted(aspect: imageAspect, in: area)
            let scale = Geometry.cropScale(width: fit.width, height: fit.height, degrees: rotation)
            let _ = scale
            let frame = centered(fit, in: area)
            let guidePoint = frame.minY + guideY * frame.height
            let comparing = interactive && !showOriginal

            ZStack(alignment: .topLeading) {
                photoLayer(fit, rotation: rotation, area: area, crop: crop, fixed: interactive)

                if comparing && !cropMode && compare == .overlay {
                    photoLayer(originalFit, rotation: 0, area: area, fixed: false).opacity(overlayOpacity)
                }
                if comparing && !cropMode && compare == .split {
                    photoLayer(originalFit, rotation: 0, area: area, fixed: false)
                        .mask(alignment: .leading) { Rectangle().frame(width: splitX * area.width) }
                }

                // Fine lines / thirds are a leveling and cropping aid: not on the quiet default view.
                if levelMode || cropMode {
                    GridOverlay(mode: gridMode, horizontalOnly: horizontalOnly)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }

                // Only for a confident, undecided tilt, and only in the level tool or while hovering the chip.
                if library.hasSuggestion(photo), !showOriginal, (levelMode && showDetected) || chipHover, let d = photo.detection {
                    HorizonLine(degrees: d.angle + rotation)
                        .frame(width: fit.width, height: fit.height)
                        .offset(x: (area.width - fit.width) / 2, y: (area.height - fit.height) / 2 + lineShift * fit.height)
                    if interactive && levelMode && pick.isEmpty { suggestionGrab(degrees: d.angle + rotation, frame: frame) }
                }

                if interactive && cropMode {
                    CropOverlay(rect: $cropDraft, ratio: normalizedCropRatio, matte: [Theme.ground, Theme.raised.opacity(0.5)])
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                } else if interactive {
                    if comparing && compare == .split { splitHandle(area: area) }
                    if levelMode {
                        if showGuide { guideLine(frame: frame, y: guidePoint) }
                        pickLayer(fit: fit, rotation: rotation, area: area)
                    } else if !showOriginal {
                        // The corner chip, top-right inside the photo.
                        Color.clear
                            .frame(width: frame.width, height: frame.height)
                            .overlay(alignment: .topTrailing) { chip.padding(10) }
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
            .frame(width: area.width, height: area.height)
            .clipped()
            .contentShape(Rectangle())
            .coordinateSpace(name: "canvas")
            // Right-click the photo: the same menu as in the list (decide, ♥, copy, save, trash, fixes…),
            // for this photo or the whole selection.
            .contextMenu {
                if interactive && !cropMode && !fixesMode { StatusMenu(ids: library.targets(for: photo.id)) }
            }
            .gesture(interactive && levelMode ? pickGesture(photo: frame) : nil)
            .onContinuousHover(coordinateSpace: .named("canvas")) { phase in
                guard interactive, levelMode, pick.points.count == 1, pick.active == nil else { if pick.hover != nil { pick.hover = nil }; return }
                if case .active(let p) = phase, frame.contains(p) { pick.hover = p } else { pick.hover = nil }
            }
            .onChange(of: frame) { pickFrame = frame }
            .onAppear { pickFrame = frame }
            .animation(.easeOut(duration: 0.15), value: pick.isComplete)
            .overlay(alignment: .bottom) { if interactive && levelMode { pickBar } }
            .overlay(alignment: guideY > 0.62 ? .top : .bottom) {
                if interactive && levelMode && showGuide && showLoupes && image != nil {
                    HStack {
                        loupe(fit: fit, rotation: rotation, area: area, focus: CGPoint(x: frame.minX + frame.width * 0.06, y: guidePoint), label: "Left end")
                        Spacer()
                        loupe(fit: fit, rotation: rotation, area: area, focus: CGPoint(x: frame.maxX - frame.width * 0.06, y: guidePoint), label: "Right end")
                    }
                    .padding(10)
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if showOriginal { badge(floating ? "Original" : "Original · Space for the result", .white) }
                else if let caption { badge(caption, .white) }
            }
            .overlay(alignment: .topTrailing) {
                if interactive, !showOriginal, compare == .split {
                    Text("Before | After").font(.caption).padding(6)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4)).padding(10)
                }
            }
        }
        .background(Theme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.8)))
            .foregroundStyle(color)
            .padding(.top, 12)
            .allowsHitTesting(false)
    }

    // MARK: Corner chip

    /// "Tilted 1.4° · Level L" for a confident tilt (hover previews, click or L levels), then "Leveled · Undo"
    /// for ~4 s. Nothing at all otherwise.
    @ViewBuilder private var chip: some View {
        Group {
            if library.justLeveled.contains(photo.id) {
                HStack(spacing: 6) {
                    Text(library.justLeveled.count == 1 ? "Leveled" : "Leveled \(library.justLeveled.count)")
                    Text("·").opacity(0.5)
                    Button { library.undoQuickLevel() } label: { Text("Undo").fontWeight(.semibold) }
                        .buttonStyle(.plain)
                        .help("Back to undecided")
                }
                .chipStyle()
            } else if library.hasSuggestion(photo), let d = photo.detection {
                Button { chipHover = false; peek = nil; library.quickLevel(library.targets(for: photo.id)) } label: {
                    HStack(spacing: 6) {
                        Text("Tilted " + Geometry.format(d.angle)).monospacedDigit()
                        Text("·").opacity(0.5)
                        Text("Level").fontWeight(.semibold)
                        Text("L").opacity(0.5)
                    }
                    .chipStyle()
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    chipHover = inside
                    peek = inside ? DecisionSwitch.levelTarget(photo) : nil
                }
                .help("Hover to preview · click or L to level · K keeps it as shot")
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.25), value: library.justLeveled)
    }

    private func toggleLevelTool() { library.levelTool ? closeLevelTool() : openLevelTool() }

    private func openLevelTool() {
        if cropMode { cancelCrop() }
        library.fixesTool = false
        chipHover = false; peek = nil
        withAnimation(.easeOut(duration: 0.15)) { library.levelTool = true }
    }

    private func closeLevelTool() {
        pick.clear()
        withAnimation(.easeOut(duration: 0.15)) { library.levelTool = false }
    }

    // MARK: Guide line and loupes

    private static let guideColor = Color.white

    private func guideLine(frame: CGRect, y: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Path { p in p.move(to: CGPoint(x: frame.minX, y: y)); p.addLine(to: CGPoint(x: frame.maxX, y: y)) }
                .stroke(.black.opacity(0.6), lineWidth: 3)
            Path { p in p.move(to: CGPoint(x: frame.minX, y: y)); p.addLine(to: CGPoint(x: frame.maxX, y: y)) }
                .stroke(Self.guideColor, lineWidth: 1)
            ForEach([frame.minX, frame.maxX], id: \.self) { x in
                Circle().fill(Self.guideColor).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.black.opacity(0.6)))
                    .position(x: x, y: y)
            }
            // Wide invisible strip so the line is easy to grab.
            Rectangle().fill(Color.white.opacity(0.001))
                .frame(width: frame.width, height: 16)
                .offset(x: frame.minX, y: y - 8)
                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                        .onChanged { g in guideY = min(max((g.location.y - frame.minY) / frame.height, 0.02), 0.98) }
                        .onEnded { g in
                            // Double-click: back to the middle.
                            if abs(g.translation.height) < 2, (NSApp.currentEvent?.clickCount ?? 1) >= 2 { guideY = 0.5 }
                        }
                )
                .help("Drag onto the horizon")
        }
    }

    /// A thin invisible band (±6 pt) along the dashed suggested horizon: ↕ pointer, drag to move it up or down
    /// at its angle, double-click to put it back. Clicks elsewhere still go to the two-point picker.
    private func suggestionGrab(degrees: Double, frame: CGRect) -> some View {
        let r = degrees * .pi / 180
        return Rectangle().fill(Color.white.opacity(0.001))
            .frame(width: frame.width / max(abs(cos(r)), 0.2), height: 12)
            .rotationEffect(.degrees(-degrees))
            .position(x: frame.midX, y: frame.midY + lineShift * frame.height)
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                    .onChanged { g in
                        if lineDragStart == nil { lineDragStart = lineShift }
                        lineShift = min(max((lineDragStart ?? 0) + g.translation.height / max(frame.height, 1), -0.5), 0.5)
                    }
                    .onEnded { g in
                        lineDragStart = nil
                        if abs(g.translation.height) < 2, (NSApp.currentEvent?.clickCount ?? 1) >= 2 { lineShift = 0 }
                    }
            )
            .help("Drag the suggested horizon onto the real one · double-click to reset")
    }

    private func loupe(fit: CGSize, rotation: Double, area: CGSize, focus: CGPoint, label: String) -> some View {
        let size = CGSize(width: 200, height: 120)
        let zoom: CGFloat = 5
        return photoLayer(fit, rotation: rotation, area: area, crop: displayCrop)
            .scaleEffect(zoom, anchor: UnitPoint(x: focus.x / max(area.width, 1), y: focus.y / max(area.height, 1)))
            .offset(x: size.width / 2 - focus.x, y: size.height / 2 - focus.y)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .overlay {
                Canvas { ctx, s in
                    var fine = Path()
                    var y = s.height / 2 - 60
                    while y <= s.height / 2 + 60 {
                        if abs(y - s.height / 2) > 1 { fine.move(to: CGPoint(x: 0, y: y)); fine.addLine(to: CGPoint(x: s.width, y: y)) }
                        y += 6
                    }
                    ctx.stroke(fine, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
                    var mid = Path()
                    mid.move(to: CGPoint(x: 0, y: s.height / 2)); mid.addLine(to: CGPoint(x: s.width, y: s.height / 2))
                    ctx.stroke(mid, with: .color(.black.opacity(0.6)), lineWidth: 3)
                    ctx.stroke(mid, with: .color(Self.guideColor), lineWidth: 1)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(label + " ×5").font(.caption2).padding(4)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3)).padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Self.guideColor.opacity(0.8), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 6)
    }

    private func splitHandle(area: CGSize) -> some View {
        let x = splitX * area.width
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.white).frame(width: 2, height: area.height).offset(x: x - 1)
            Circle().fill(.white).frame(width: 26, height: 26)
                .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.black))
                .position(x: x, y: area.height / 2)
            Rectangle().fill(Color.white.opacity(0.001)).frame(width: 24, height: area.height).offset(x: x - 12)
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                        .onChanged { g in splitX = min(max(g.location.x / area.width, 0), 1) }
                )
        }
    }

    // MARK: Picking the horizon (two points, Apple Notes–style magnifiers)

    /// Press to place a point (a magnifier follows while held), press again for the other end,
    /// drag either end to fine-tune, then ↵ to level along the line. Esc cancels.
    private func pickGesture(photo frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { v in
                if pick.active == nil && pick.start == nil { focused = true; pick.press(at: v.startLocation, within: frame) }
                pick.move(to: v.location, within: frame)
            }
            .onEnded { _ in pick.release() }
    }

    /// The picked line, its magnifiers, and the confirm bar.
    @ViewBuilder private func pickLayer(fit: CGSize, rotation: Double, area: CGSize) -> some View {
        LinePickOverlay(pick: pick)
        if pick.points.count == 1, pick.active == nil, let h = pick.hover {
            PointLoupe(canvas: area, focus: h) {
                ZStack(alignment: .topLeading) {
                    photoLayer(fit, rotation: rotation, area: area, crop: displayCrop)
                    LinePickOverlay(pick: pick)
                }
            }
            .position(PointLoupe<EmptyView>.position(for: h, in: area))
        }
        ForEach(Array(pick.points.enumerated()), id: \.offset) { i, pt in
            if pick.active == i || (pick.isComplete && pick.active == nil) {
                PointLoupe(canvas: area, focus: pt) {
                    ZStack(alignment: .topLeading) {
                        photoLayer(fit, rotation: rotation, area: area, crop: displayCrop)
                        LinePickOverlay(pick: pick)
                    }
                }
                .position(PointLoupe<EmptyView>.position(for: pt, in: area))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }

    @ViewBuilder private var pickBar: some View {
        if pick.isComplete && pick.active == nil {
            let next = shown - Geometry.lineTilt(from: pick.points[0], to: pick.points[1])
            HStack(spacing: 10) {
                Text(Geometry.format(next)).font(.callout.weight(.medium)).monospacedDigit()
                Button { applyPick() } label: {
                    HStack(spacing: 6) { Text("Level along this line"); Text("↵").opacity(0.5) }
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .foregroundStyle(.black).background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                Button { pick.clear() } label: { Image(systemName: "xmark").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).help("Cancel (Esc)")
            }
            .foregroundStyle(.white)
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 6)
            .background(.black.opacity(0.7), in: Capsule())
            .padding(.bottom, 14)
        } else if pick.points.count == 1 && pick.active == nil {
            Text("Now click the other end · arrows nudge the dot · Esc to cancel")
                .font(.callout).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(.bottom, 14)
                .allowsHitTesting(false)
        }
    }

    private func applyPick() {
        guard pick.isComplete else { return }
        level(from: pick.points[0], to: pick.points[1], label: "Two points")
        pick.clear()
    }

    private func level(from a: CGPoint, to b: CGPoint, label: String) {
        let next = shown - Geometry.lineTilt(from: a, to: b)
        library.setCorrection(photo.id, next, label: label + " " + Geometry.format(next))
    }


    // MARK: Crop

    /// The locked ratio in 0…1 units of the leveled frame (nil = free).
    private var normalizedCropRatio: CGFloat? {
        cropRatio.value(photoAspect: imageAspect, portrait: cropPortrait).map { $0 / imageAspect }
    }

    private func startCrop() {
        library.fixesTool = false
        pick.clear()
        showOriginal = false
        cropDraft = photo.crop ?? CropMath.full
        cropPortrait = false
        if photo.crop == nil, let n = normalizedCropRatio { cropDraft = CropMath.fit(ratio: n, around: CGPoint(x: 0.5, y: 0.5)) }
        withAnimation(.easeOut(duration: 0.15)) { cropMode = true }
    }

    private func applyRatio() {
        guard let n = normalizedCropRatio else { return }
        cropDraft = CropMath.fit(ratio: n, around: CGPoint(x: cropDraft.midX, y: cropDraft.midY))
    }

    private func finishCrop() {
        let full = cropDraft.width > 0.995 && cropDraft.height > 0.995
        library.setCrop(photo.id, full ? nil : cropDraft, label: full ? "Crop removed" : "Crop " + (cropRatio == .free ? "" : cropRatio.label(flipped: cropPortrait)))
        withAnimation(.easeOut(duration: 0.15)) { cropMode = false }
    }

    private func cancelCrop() { withAnimation(.easeOut(duration: 0.15)) { cropMode = false } }

    /// "+ Version" (V): keeps the frame as it is now as a version; editing goes on.
    private func addVersion() {
        let label = cropRatio == .free ? "Free" : cropRatio.label(flipped: cropPortrait)
        library.addCropVersion(photo.id, rect: cropDraft, ratio: label)
    }

    /// A version clicked in the strip goes back into the frame, with its ratio lock, to keep editing.
    private func loadVersion(_ v: CropVersion) {
        if let m = CropRatio.matching(v.ratio) { cropRatio = m.ratio; cropPortrait = m.flipped } else { cropRatio = .free }
        withAnimation(.easeOut(duration: 0.15)) { cropDraft = v.rect }
    }

    private var cropBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(CropRatio.allCases) { r in
                    Button { cropRatio = r; applyRatio() } label: {
                        Text(r.label(flipped: cropRatio == r && cropPortrait)).font(.callout.weight(cropRatio == r ? .semibold : .regular))
                            .padding(.horizontal, 10).frame(height: 28)
                            .foregroundStyle(cropRatio == r ? Theme.ground : .primary)
                            .background(cropRatio == r ? Color.primary : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { cropPortrait.toggle(); applyRatio() } label: {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!cropRatio.flippable)
            .help("Flip the ratio (4:5 ↔ 5:4)")
            Spacer()
            Button("Reset") { cropDraft = CropMath.full; if cropRatio != .free && cropRatio != .original { cropRatio = .original } }
            Button("Cancel") { cancelCrop() }.keyboardShortcut(.cancelAction)
            Button { finishCrop() } label: {
                Text("Done").fontWeight(.semibold).padding(.horizontal, 16).frame(height: 30)
                    .foregroundStyle(Theme.ground).background(Color.primary, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    // MARK: Keys

    private func decide(_ d: Decision) {
        library.decideAndMove(library.targets(for: photo.id), d)
    }

    private func cycle<T: CaseIterable & Equatable>(_ value: T) -> T {
        let all = Array(T.allCases)
        let i = all.firstIndex(of: value) ?? all.startIndex
        return all[(i + 1) % all.count]
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if fixesMode {
            // Esc / ↵ close Fixes; arrows still move between photos (the panel stays open); nothing else.
            guard press.phase == .down else { return .handled }
            switch press.key {
            case .escape, .return: library.fixesTool = false
            case .leftArrow, .upArrow: library.step(-1)
            case .rightArrow, .downArrow: library.step(1)
            default: return .ignored
            }
            return .handled
        }
        if cropMode {
            guard press.phase == .down else { return .handled }
            if press.key == .return { finishCrop() } else if press.key == .escape { cancelCrop() }
            else if press.characters == "v" || press.characters == "V" { addVersion() }
            else if press.characters == "C", !photo.cropVersions.isEmpty { showStudio = true }
            return .handled
        }
        // Space: quick look (full window). Hold M: the original, like Apple Photos.
        if press.key == .space {
            if press.phase == .down {
                if floating { library.quickLook = false }
                else { withAnimation(.easeOut(duration: 0.12)) { showOriginal.toggle() } }
            }
            return .handled
        }
        if press.characters.lowercased() == "m" {
            if press.phase != .repeat { showOriginal = press.phase != .up }
            return .handled
        }
        guard press.phase != .up else { return .ignored }
        if press.modifiers.contains(.command) { return .ignored }
        switch press.key {
        // While picking, arrows nudge the end you touched last (⇧ for bigger steps) instead of changing photos.
        case .leftArrow where !pick.isEmpty: pick.nudge(dx: press.modifiers.contains(.shift) ? -5 : -0.5, dy: 0, within: pickFrame); return .handled
        case .rightArrow where !pick.isEmpty: pick.nudge(dx: press.modifiers.contains(.shift) ? 5 : 0.5, dy: 0, within: pickFrame); return .handled
        case .upArrow where !pick.isEmpty: pick.nudge(dx: 0, dy: press.modifiers.contains(.shift) ? -5 : -0.5, within: pickFrame); return .handled
        case .downArrow where !pick.isEmpty: pick.nudge(dx: 0, dy: press.modifiers.contains(.shift) ? 5 : 0.5, within: pickFrame); return .handled
        case .leftArrow: library.step(-1); return .handled
        case .rightArrow: library.step(1); return .handled
        case .upArrow: library.step(floating && library.gridActive ? -library.gridColumns : -1); return .handled
        case .downArrow: library.step(floating && library.gridActive ? library.gridColumns : 1); return .handled
        case .return where pick.isComplete:
            applyPick(); return .handled
        case .return where levelMode:
            closeLevelTool(); return .handled
        case .escape:
            if !pick.isEmpty { pick.clear() } else if levelMode { closeLevelTool() } else { library.quickLook = false }
            return .handled
        case .delete, .deleteForward:
            // Delete (and ⌘⌫ from the menu): the photo, or the whole selection it's part of. ⌘Z puts it back.
            library.requestDelete(library.targets(for: photo.id)); return .handled
        default: break
        }
        let repeatable: Set<String> = ["[", "]", "{", "}"]
        if press.phase == .repeat && !repeatable.contains(press.characters) { return .handled }
        switch press.characters {
        case "l", "L": library.quickLevel(library.targets(for: photo.id))
        case "k", "K": decide(.keep)
        case "u", "U": decide(.undecided)
        case "f", "F": library.toggleFavorite(library.targets(for: photo.id))
        case "[": library.nudge(photo.id, by: 0.1)
        case "]": library.nudge(photo.id, by: -0.1)
        case "{": library.nudge(photo.id, by: 1)
        case "}": library.nudge(photo.id, by: -1)
        case "r", "R": toggleLevelTool()
        case "0": library.resetToOriginal([photo.id])
        case "g", "G": gridMode = cycle(gridMode)
        case "t", "T": showGuide.toggle()
        case "c": startCrop()
        case "C": if photo.cropVersions.isEmpty { startCrop() } else { showStudio = true }
        case "h", "H": showDetected.toggle()
        case "i", "I": showInfo.toggle()
        case "s", "S": withAnimation { library.showSettings.toggle() }
        default: return .ignored
        }
        return .handled
    }
}

struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + 6; row = 0 }
            x += size.width + spacing
            maxX = max(maxX, x)
            row = max(row, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + 6; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
