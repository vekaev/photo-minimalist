import SwiftUI

enum Lines: String, CaseIterable, Identifiable {
    case off, thirds, fine
    var id: String { rawValue }
    var label: String { self == .off ? "No lines" : self == .thirds ? "Thirds" : "Fine lines" }
}

/// One photo, full screen: by default just the photo (swipe sideways for the next one). A confident tilt shows as a
/// small corner chip: tap = level, hold = preview. The level button opens the level tool: touch both ends of the
/// horizon (a magnifier shows under your finger), drag to fine-tune, "Level along this line", or use the ruler.
/// Tap the eye to flip original ⇄ result.
struct EditorView: View {
    @Environment(Library.self) private var library
    @AppStorage("ios.lines") private var lines: Lines = .fine
    @AppStorage("ios.guide") private var showGuide = true
    @AppStorage("ios.detected") private var showDetected = false

    @State private var image: CGImage?
    @State private var preview: Double?
    /// Holding a side of the As shot | Level switch shows that result before lifting the finger.
    @State private var peek: Double?
    @State private var showOriginal = false
    @State private var pick = LinePick()
    @State private var cropMode = false
    @State private var cropDraft = CropMath.full
    @AppStorage("ios.cropRatio") private var cropRatio: CropRatio = .original
    @State private var cropPortrait = false
    @State private var guideY: CGFloat = 0.5
    /// The dashed suggested horizon, dragged up or down (fraction of the photo's height). Reset per photo.
    @State private var lineShift: CGFloat = 0
    @State private var lineDragStart: CGFloat?
    /// Crop studio: every version side by side.
    @State private var showStudio = false
    /// The details sheet (ⓘ): date, camera, exposure, sizes.
    @State private var showInfo = false
    /// Holding the corner chip: preview the leveled photo and show the suggested line.
    @State private var chipHold = false

    /// The level tool is open (shared with the Mac's R; stays open from photo to photo until Done).
    private var levelMode: Bool { library.levelTool && !cropMode }

    private var photo: Photo? { library.photo(library.openedID) }

    var body: some View {
        if let photo {
            VStack(spacing: 0) {
                topBar(photo)
                canvas(photo)
                    .padding(.horizontal, 8)
                if cropMode {
                    CropVersionStrip(photo: photo, image: image, draft: cropDraft, height: 44,
                                     onAdd: { addVersion(photo) }, onLoad: loadVersion, onCompare: { showStudio = true })
                        .padding(.horizontal, 16).padding(.top, 10)
                    cropBar(photo)
                } else if levelMode { controls(photo) }
            }
            .background(Color(.systemBackground))
            .deleteConfirmation(active: true)
            .sheet(isPresented: $showInfo) {
                ScrollView { PhotoInfoCard(photo: photo).frame(maxWidth: .infinity, alignment: .leading).padding(20) }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .task(id: photo.url) { await library.fillInfo(photo) }
            }
            .sheet(isPresented: $showStudio) {
                CropStudio(photo: photo, image: image, onChoose: { v in
                    library.chooseCropVersion(photo.id, v.id)
                    showStudio = false
                    withAnimation(.easeOut(duration: 0.15)) { cropMode = false }
                }, onClose: { showStudio = false })
            }
            // Settings slide up from the bottom; swipe down to close.
            .sheet(isPresented: Binding(get: { library.showSettings }, set: { library.showSettings = $0 })) {
                SettingsSheet(photo: photo, lines: $lines, showGuide: $showGuide, showDetected: $showDetected)
                    .presentationDetents([.height(380), .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .height(380)))
            }
            // History from the settings sheet: the folder's activity, "This photo" filters to this one.
            .sheet(isPresented: Binding(get: { library.showActivity }, set: { library.showActivity = $0 })) {
                ActivityView(photoID: photo.id).environment(library)
            }
            .onAppear { if image == nil { image = ImageCache.shared.cached(for: photo.url) } }
            .onChange(of: photo.id) { image = ImageCache.shared.cached(for: photo.url) }
            .onChange(of: library.levelTool) { if !library.levelTool { pick.clear(); preview = nil; peek = nil } }
            .task(id: photo.url) {
                pick.clear()
                peek = nil
                chipHold = false
                showOriginal = false
                cropMode = false
                lineShift = 0
                showStudio = false
                if image == nil {
                    image = await ImageCache.shared.image(for: photo.url, rawCompanion: photo.rawCompanion, maxPixel: 420)
                }
                if let sharp = await ImageCache.shared.image(for: photo.url, rawCompanion: photo.rawCompanion, maxPixel: 2400) {
                    image = sharp
                }
                if let image { photo.analysisAspect = CGFloat(image.width) / CGFloat(image.height) }
            }
        }
    }

    private func shown(_ p: Photo) -> Double {
        if showOriginal { return 0 }
        return preview ?? peek ?? p.appliedCorrection
    }

    // MARK: Top: close, position, the chosen buttons (Settings ▸ Editor buttons), settings

    @AppStorage(PhotoControl.phoneKey) private var controlsRaw = PhotoControl.defaultValue(.phone)
    @State private var barWidth: CGFloat = 0

    private func topBar(_ p: Photo) -> some View {
        let i = (library.navigation.firstIndex(of: p.id) ?? 0) + 1
        let all = PhotoControl.parse(controlsRaw, on: .phone)
        // Close, the counter and settings always stay; the chosen buttons get the rest, extras go into ⋯.
        let counter = "\(i) / \(library.navigation.count)"
        let counterWidth = ceil((counter as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .footnote)]).width) + 4 + 18
        let room = Double(barWidth) - 16 - 44 - 44 - Double(counterWidth) - 4
        let shown = barWidth == 0 ? all.count : PhotoControl.fitting(all.map { _ in 44 }, in: room, spacing: 0, overflowWidth: 44)
        return HStack(spacing: 0) {
            iconButton("chevron.down", "Close") { library.closePhoto() }
            Spacer(minLength: 0)
            // The position doubles as the ⓘ button (no room for another icon): date, camera, exposure, sizes.
            Button { showInfo = true } label: {
                HStack(spacing: 4) {
                    Text(counter).monospacedDigit()
                    Image(systemName: "info.circle")
                }
                .font(.footnote).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Info, photo \(i) of \(library.navigation.count)")
            Spacer(minLength: 0)
            ForEach(all.prefix(shown)) { c in
                Button { perform(c, p) } label: {
                    Image(systemName: symbol(c, p))
                        .font(.system(size: 17, weight: c == .level && levelMode ? .bold : .medium))
                        .foregroundStyle(c == .favorite && p.favorite ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .disabled(!enabled(c, p))
                .accessibilityLabel(accessibility(c, p))
            }
            if shown < all.count {
                Menu {
                    ForEach(all.dropFirst(shown)) { c in
                        Button(role: c == .trash ? .destructive : nil) { perform(c, p) } label: { Label(c.title, systemImage: symbol(c, p)) }
                            .disabled(!enabled(c, p))
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("More")
            }
            // Always here: the settings sheet is where the buttons above are chosen. Long-press: Move to Trash.
            iconButton("slider.horizontal.3", "Settings") { library.showSettings = true }
                .contextMenu {
                    Button(role: .destructive) { library.requestDelete([p.id]) } label: { Label("Move to Trash", systemImage: "trash") }
                }
        }
        .padding(.horizontal, 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
    }

    /// The same functions as the rest of the editor (and the Mac's shortcuts).
    private func perform(_ c: PhotoControl, _ p: Photo) {
        switch c {
        case .level: toggleLevelTool()
        case .crop: cropMode ? (cropMode = false) : startCrop(p)
        case .favorite: library.toggleFavorite([p.id])
        case .original: withAnimation(.easeOut(duration: 0.12)) { showOriginal.toggle() }
        case .history: library.showActivity = true
        case .copy: library.copyPhotos([p], kind: .asShown)
        case .save: Task { await library.saveToOriginalsWithToast([p.id]) }
        case .trash: library.requestDelete([p.id])
        case .photos: library.addToPhotos([p.id])
        case .undo: library.undo()
        case .info: showInfo = true
        case .viewOptions: library.showSettings = true
        case .compare, .export: break   // not on iPhone (see PhotoControl.available)
        }
    }

    private func enabled(_ c: PhotoControl, _ p: Photo) -> Bool {
        switch c {
        case .undo: return library.canUndo
        case .save: return !library.savable([p.id]).isEmpty
        default: return true
        }
    }

    private func symbol(_ c: PhotoControl, _ p: Photo) -> String {
        switch c {
        case .favorite: return p.favorite ? "heart.fill" : "heart"
        case .original: return showOriginal ? "eye.fill" : "eye"
        default: return c.symbol
        }
    }

    private func accessibility(_ c: PhotoControl, _ p: Photo) -> String {
        switch c {
        case .favorite: return p.favorite ? "Unfavorite" : "Favorite"
        case .original: return showOriginal ? "Show the result" : "Show the original"
        case .level: return levelMode ? "Close the level tool" : "Level tool"
        default: return c.title
        }
    }

    private func toggleLevelTool() {
        if cropMode { cropMode = false }
        peek = nil; chipHold = false
        if library.levelTool { pick.clear() }
        withAnimation(.easeOut(duration: 0.15)) { library.levelTool.toggle() }
    }

    private func iconButton(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    // MARK: Photo

    private func canvas(_ p: Photo) -> some View {
        GeometryReader { geo in
            let area = geo.size
            let rotation = shown(p)
            let crop = cropMode || showOriginal ? nil : p.appliedCrop
            let aspect = Geometry.finalAspect(imageAspect, crop: crop)
            let fitW = min(area.width, area.height * aspect)
            let fit = CGSize(width: fitW, height: fitW / aspect)
            // Final result only: the photo fills its frame, cropped, with no tilted edges around it.
            let frame = CGRect(x: (area.width - fit.width) / 2, y: (area.height - fit.height) / 2, width: fit.width, height: fit.height)

            ZStack(alignment: .topLeading) {
                photoLayer(fit: fit, rotation: rotation, area: area, crop: crop)
                if cropMode {
                    CropOverlay(rect: $cropDraft, ratio: normalizedCropRatio, matte: [Color(.systemBackground)])
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                } else if !levelMode {
                    // Quiet default: just the photo, plus the corner chip for a confident tilt.
                    if chipHold, library.hasSuggestion(p), let d = p.detection {
                        detectedLine(angle: d.angle + rotation, in: frame, draggable: false)
                    }
                    if !showOriginal {
                        Color.clear
                            .frame(width: frame.width, height: frame.height)
                            .overlay(alignment: .topTrailing) { chip(p).padding(8) }
                            .offset(x: frame.minX, y: frame.minY)
                    }
                } else {
                LineOverlay(lines: lines)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                // Only for a confident, undecided tilt.
                if showDetected, library.hasSuggestion(p), let d = p.detection {
                    detectedLine(angle: d.angle + rotation, in: frame, draggable: pick.isEmpty)
                }
                if showGuide && !showOriginal { guide(frame) }
                LinePickOverlay(pick: pick)
                // Magnifiers: one above your finger while you hold, both ends once the line is picked.
                ForEach(Array(pick.points.enumerated()), id: \.offset) { i, pt in
                    if pick.active == i || (pick.isComplete && pick.active == nil) {
                        PointLoupe(canvas: area, focus: pt, diameter: 110) {
                            ZStack(alignment: .topLeading) {
                                photoLayer(fit: fit, rotation: rotation, area: area, crop: crop)
                                LinePickOverlay(pick: pick)
                            }
                        }
                        .position(PointLoupe<EmptyView>.position(for: pt, in: area, diameter: 110, lift: 70))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                }
            }
            .frame(width: area.width, height: area.height)
            .clipped()
            .contentShape(Rectangle())
            .coordinateSpace(name: "photo")
            // Default view: swipes always change photos.
            .gesture(cropMode || levelMode ? nil :
                DragGesture(minimumDistance: 20, coordinateSpace: .named("photo"))
                    .onEnded { v in
                        let w = v.translation.width, h = v.translation.height
                        if abs(w) > 60 && abs(w) > abs(h) * 1.5 {
                            withAnimation(.easeOut(duration: 0.2)) { library.step(w < 0 ? 1 : -1) }
                        }
                    }
            )
            .gesture(!levelMode ? nil :
                // Touch to place a point (magnifier above the finger), drag to fine-tune, lift to set it.
                // A quick sideways swipe that started a new point is a swipe to the next photo instead.
                DragGesture(minimumDistance: 0, coordinateSpace: .named("photo"))
                    .onChanged { v in
                        if pick.active == nil && pick.start == nil { pick.press(at: v.startLocation, within: frame) }
                        pick.move(to: v.location, within: frame)
                    }
                    .onEnded { v in
                        let w = v.translation.width, h = v.translation.height
                        let swipe = pick.created && abs(w) > 70 && abs(w) > abs(h) * 1.8
                            && abs(v.predictedEndTranslation.width) > abs(w) * 1.3
                        if swipe {
                            pick.clear()
                            withAnimation(.easeOut(duration: 0.2)) { library.step(w < 0 ? 1 : -1) }
                        } else {
                            pick.release()
                        }
                    }
            )
            .animation(.easeOut(duration: 0.15), value: pick.isComplete)
            .overlay(alignment: .bottom) { if levelMode { pickBar(p) } }
            .overlay(alignment: .top) {
                if let hint = hint(p) {
                    Text(hint)
                        .font(.footnote)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 10)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// "Tilted 1.4° · Level" for a confident tilt (tap levels, hold previews), then "Leveled · Undo" for ~4 s.
    @ViewBuilder private func chip(_ p: Photo) -> some View {
        Group {
            if library.justLeveled.contains(p.id) {
                Button { library.undoQuickLevel() } label: {
                    HStack(spacing: 6) {
                        Text(library.justLeveled.count == 1 ? "Leveled" : "Leveled \(library.justLeveled.count)")
                        Text("·").opacity(0.5)
                        Text("Undo").fontWeight(.semibold)
                    }
                    .chipStyle()
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Leveled. Undo")
            } else if library.hasSuggestion(p), let d = p.detection {
                HStack(spacing: 6) {
                    Text("Tilted " + Geometry.format(d.angle)).monospacedDigit()
                    Text("·").opacity(0.5)
                    Text("Level").fontWeight(.semibold)
                }
                .chipStyle()
                .frame(minHeight: 44).contentShape(Rectangle())
                .onTapGesture { chipHold = false; peek = nil; library.quickLevel([p.id]) }
                .onLongPressGesture(minimumDuration: 0.25, perform: {}, onPressingChanged: { held in
                    chipHold = held
                    peek = held ? DecisionSwitch.levelTarget(p) : nil
                })
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Tilted \(Geometry.format(d.angle)). Level")
                .accessibilityHint("Hold to preview")
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.25), value: library.justLeveled)
    }

    private func hint(_ p: Photo) -> String? {
        if showOriginal { return "Original · tap the eye for the result" }
        if p.decision == .keep { return "Kept as shot" }
        return nil
    }

    private func photoLayer(fit: CGSize, rotation: Double, area: CGSize, crop: CGRect?) -> some View {
        ZStack {
            if let image { EditedImage(image: image, rotation: rotation, crop: crop) }
        }
        .frame(width: fit.width, height: fit.height)
        .frame(width: area.width, height: area.height)
    }

    private var imageAspect: CGFloat { image.map { CGFloat($0.width) / CGFloat($0.height) } ?? 1.5 }

    // MARK: Crop

    private var normalizedCropRatio: CGFloat? {
        cropRatio.value(photoAspect: imageAspect, portrait: cropPortrait).map { $0 / imageAspect }
    }

    private func startCrop(_ p: Photo) {
        pick.clear()
        showOriginal = false
        cropDraft = p.crop ?? CropMath.full
        cropPortrait = false
        if p.crop == nil, let n = normalizedCropRatio { cropDraft = CropMath.fit(ratio: n, around: CGPoint(x: 0.5, y: 0.5)) }
        withAnimation(.easeOut(duration: 0.15)) { cropMode = true }
    }

    private func applyRatio() {
        guard let n = normalizedCropRatio else { return }
        cropDraft = CropMath.fit(ratio: n, around: CGPoint(x: cropDraft.midX, y: cropDraft.midY))
    }

    private func cropBar(_ p: Photo) -> some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(CropRatio.allCases) { r in
                        Button { cropRatio = r; applyRatio() } label: {
                            Text(r.label(flipped: cropRatio == r && cropPortrait)).font(.subheadline.weight(cropRatio == r ? .semibold : .regular))
                                .padding(.horizontal, 12).frame(height: 32)
                                .foregroundStyle(cropRatio == r ? Color(.systemBackground) : .primary)
                                .background(cropRatio == r ? Color.primary : Color.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Button { cropPortrait.toggle(); applyRatio() } label: {
                        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90").frame(width: 40, height: 32)
                    }
                    .disabled(!cropRatio.flippable)
                    .accessibilityLabel("Flip the ratio")
                }
                .padding(.horizontal, 20)
            }
            HStack(spacing: 12) {
                Button { cropDraft = CropMath.full } label: {
                    Text("Reset").frame(maxWidth: .infinity, minHeight: 50)
                        .overlay(Capsule().strokeBorder(Ink.rule, lineWidth: 1))
                }
                Button {
                    let full = cropDraft.width > 0.995 && cropDraft.height > 0.995
                    library.setCrop(p.id, full ? nil : cropDraft, label: full ? "Crop removed" : "Crop " + (cropRatio == .free ? "" : cropRatio.label(flipped: cropPortrait)))
                    withAnimation(.easeOut(duration: 0.15)) { cropMode = false }
                } label: {
                    Text("Done").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(Color(.systemBackground)).background(Color.primary, in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
        }
        .padding(.top, 14).padding(.bottom, 8)
    }

    @ViewBuilder private func pickBar(_ p: Photo) -> some View {
        if pick.isComplete && pick.active == nil {
            let next = shown(p) - Geometry.lineTilt(from: pick.points[0], to: pick.points[1])
            HStack(spacing: 10) {
                Text(Geometry.format(next)).font(.subheadline.weight(.medium)).monospacedDigit()
                Button {
                    library.setCorrection(p.id, next, label: "Two points " + Geometry.format(next))
                    pick.clear()
                } label: {
                    Text("Level along this line").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .foregroundStyle(.black).background(.white, in: Capsule())
                }
                Button { pick.clear() } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }
                    .accessibilityLabel("Cancel")
            }
            .foregroundStyle(.white)
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 5)
            .background(.black.opacity(0.7), in: Capsule())
            .padding(.bottom, 10)
        } else if pick.points.count == 1 && pick.active == nil {
            Text("Now touch the other end of the horizon")
                .font(.footnote).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(.bottom, 10)
                .allowsHitTesting(false)
        }
    }

    private func guide(_ frame: CGRect) -> some View {
        let y = frame.minY + guideY * frame.height
        return ZStack(alignment: .topLeading) {
            Path { path in path.move(to: CGPoint(x: frame.minX, y: y)); path.addLine(to: CGPoint(x: frame.maxX, y: y)) }
                .stroke(.black.opacity(0.45), lineWidth: 2.5)
            Path { path in path.move(to: CGPoint(x: frame.minX, y: y)); path.addLine(to: CGPoint(x: frame.maxX, y: y)) }
                .stroke(.white, lineWidth: 1)
            Capsule().fill(.white).frame(width: 28, height: 6)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .position(x: frame.maxX - 22, y: y)
            // Generous touch target around the line.
            Rectangle().fill(Color.white.opacity(0.001))
                .frame(width: frame.width, height: 36)
                .offset(x: frame.minX, y: y - 18)
                // Only a real drag moves the guide; taps fall through to two-point leveling.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .named("photo"))
                        .onChanged { g in guideY = min(max((g.location.y - frame.minY) / frame.height, 0.02), 0.98) }
                )
                // Double-tap: back to the middle (the taps may also have placed points; clear those).
                .simultaneousGesture(TapGesture(count: 2).onEnded { guideY = 0.5; pick.clear() })
        }
    }

    /// The dashed suggested horizon. A finger that starts a drag within the ~44 pt band along it moves it up or
    /// down (it keeps its angle); taps fall through to the two-point picker; double-tap puts it back.
    private func detectedLine(angle: Double, in frame: CGRect, draggable: Bool) -> some View {
        let r = angle * .pi / 180, len = hypot(frame.width, frame.height) / 2
        let c = CGPoint(x: frame.midX, y: frame.midY + lineShift * frame.height)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: c.x - cos(r) * len, y: c.y + sin(r) * len))
                path.addLine(to: CGPoint(x: c.x + cos(r) * len, y: c.y - sin(r) * len))
            }
            .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .allowsHitTesting(false)
            if draggable {
                Rectangle().fill(Color.white.opacity(0.001))
                    .frame(width: frame.width / max(abs(cos(r)), 0.2), height: 44)
                    .rotationEffect(.degrees(-angle))
                    .position(c)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 6, coordinateSpace: .named("photo"))
                            .onChanged { g in
                                if lineDragStart == nil { lineDragStart = lineShift }
                                lineShift = min(max((lineDragStart ?? 0) + g.translation.height / max(frame.height, 1), -0.5), 0.5)
                            }
                            .onEnded { _ in lineDragStart = nil }
                    )
                    .simultaneousGesture(TapGesture(count: 2).onEnded { lineShift = 0; pick.clear() })
                    .accessibilityHidden(true)
            }
        }
    }

    /// "+ Version": keeps the frame as it is now as a version; editing goes on.
    private func addVersion(_ p: Photo) {
        let label = cropRatio == .free ? "Free" : cropRatio.label(flipped: cropPortrait)
        library.addCropVersion(p.id, rect: cropDraft, ratio: label)
    }

    /// A version tapped in the strip goes back into the frame, with its ratio lock, to keep editing.
    private func loadVersion(_ v: CropVersion) {
        if let m = CropRatio.matching(v.ratio) { cropRatio = m.ratio; cropPortrait = m.flipped } else { cropRatio = .free }
        withAnimation(.easeOut(duration: 0.15)) { cropDraft = v.rect }
    }

    // MARK: Level tool (bottom): angle, ruler, As shot | Leveled, Done

    private func controls(_ p: Photo) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 2) {
                Text(preview.map(Geometry.format) ?? peek.map { $0 == 0 ? "Preview · as shot" : "Preview · " + Geometry.format($0) } ?? library.note(for: p))
                    .font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(p.decision == .level || preview != nil ? .primary : .secondary)
                Text(detail(p)).font(.caption).foregroundStyle(.tertiary)
            }
            // Same as the Mac: the ruler shows what's applied (0 until you level), not the suggestion.
            PhoneRuler(value: preview ?? (p.decision == .level ? p.correction : 0),
                       onChange: { preview = $0 },
                       onCommit: { v in library.setCorrection(p.id, v); preview = nil })
            HStack(spacing: 10) {
                DecisionSwitch(photo: p, large: true, decide: { decide($0, p) }, peek: { peek = $0 })
                Button { toggleLevelTool() } label: {
                    Text("Done").font(.body.weight(.semibold)).padding(.horizontal, 18).frame(minHeight: 50)
                        .foregroundStyle(Color(.systemBackground)).background(Color.primary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func detail(_ p: Photo) -> String {
        if p.decision == .keep { return "Showing it as shot · hold Level to preview" }
        if p.decision == .level { return "Showing the leveled photo · adjust with the ruler or the horizon ends" }
        guard p.analyzed else { return "Looking…" }
        guard p.detection != nil else { return "Touch both ends of the horizon to level it" }
        return library.hasSuggestion(p) ? "Showing it as shot · hold Level to preview, lift to apply" : "Keep it, or level it yourself"
    }

    private func decide(_ d: Decision, _ p: Photo) {
        let wasLast = library.navigation.last == p.id
        library.decideAndMove([p.id], d)
        // Only when moving on is turned on: at the end of the list (or if it emptied), back to the grid.
        // By default the editor stays on the photo so you see the result.
        if library.openedID == nil || (library.advanceAfterDecision && wasLast && library.openedID == p.id) { library.closePhoto() }
    }
}

/// Hairline guides drawn dark-under-light so they read on sky and water alike.
struct LineOverlay: View {
    let lines: Lines

    var body: some View {
        Canvas { ctx, size in
            var minor = Path(), major = Path()
            switch lines {
            case .off: return
            case .thirds:
                for i in 1...2 {
                    let y = size.height * CGFloat(i) / 3, x = size.width * CGFloat(i) / 3
                    major.move(to: CGPoint(x: 0, y: y)); major.addLine(to: CGPoint(x: size.width, y: y))
                    major.move(to: CGPoint(x: x, y: 0)); major.addLine(to: CGPoint(x: x, y: size.height))
                }
            case .fine:
                let step: CGFloat = 10, mid = size.height / 2
                var k = 0
                while CGFloat(k) * step < mid {
                    for y in Set([mid - CGFloat(k) * step, mid + CGFloat(k) * step]) where y > 0 && y < size.height {
                        if k % 5 == 0 {
                            major.move(to: CGPoint(x: 0, y: y)); major.addLine(to: CGPoint(x: size.width, y: y))
                        } else {
                            minor.move(to: CGPoint(x: 0, y: y)); minor.addLine(to: CGPoint(x: size.width, y: y))
                        }
                    }
                    k += 1
                }
            }
            ctx.stroke(minor, with: .color(.black.opacity(0.18)), lineWidth: 1.2)
            ctx.stroke(minor, with: .color(.white.opacity(0.28)), lineWidth: 0.4)
            ctx.stroke(major, with: .color(.black.opacity(0.28)), lineWidth: 1.6)
            ctx.stroke(major, with: .color(.white.opacity(0.55)), lineWidth: 0.6)
        }
        .allowsHitTesting(false)
    }
}

/// A thin tick ruler: drag sideways to rotate. Ticks every 0.1°, a soft click on every whole degree.
struct PhoneRuler: View {
    let value: Double
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void
    @State private var start: Double?

    private let perDegree: CGFloat = 36

    var body: some View {
        Canvas { ctx, size in
            let mid = size.width / 2
            let span = Double(mid / perDegree) + 1
            var t = (value - span).rounded(.down)
            while t <= value + span {
                for sub in 0..<10 {
                    let deg = t + Double(sub) / 10
                    guard deg >= -45, deg <= 45 else { continue }
                    let x = mid + CGFloat(deg - value) * perDegree
                    let tenth = Int((deg * 10).rounded())
                    let whole = tenth % 10 == 0, five = tenth % 50 == 0
                    let h: CGFloat = five ? 16 : whole ? 11 : 5
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: size.height - h)); p.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(p, with: .color(.primary.opacity(whole ? 0.55 : 0.22)), lineWidth: whole ? 1 : 0.5)
                    if five {
                        ctx.draw(Text("\(tenth / 10)").font(.system(size: 9)).foregroundStyle(.secondary),
                                 at: CGPoint(x: x, y: size.height - h - 8))
                    }
                }
                t += 1
            }
            var marker = Path()
            marker.move(to: CGPoint(x: mid, y: 6)); marker.addLine(to: CGPoint(x: mid, y: size.height))
            ctx.stroke(marker, with: .color(.primary), lineWidth: 1.5)
        }
        .frame(height: 40)
        .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .leading, endPoint: .trailing))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if start == nil { start = value }
                    let next = (start ?? value) - Double(g.translation.width / perDegree) * 0.5
                    onChange(min(max((next * 100).rounded() / 100, -45), 45))
                }
                .onEnded { _ in start = nil; onCommit(value) }
        )
        .sensoryFeedback(.selection, trigger: Int(value.rounded()))
        .accessibilityElement()
        .accessibilityLabel("Rotation")
        .accessibilityValue(Geometry.format(value))
        .accessibilityAdjustableAction { dir in
            onCommit(value + (dir == .increment ? 0.1 : -0.1))
        }
    }
}

/// The iPhone counterpart of the Mac settings side panel: a bottom panel you pull up and swipe away.
private struct SettingsSheet: View {
    @Environment(Library.self) private var library
    @AppStorage("ios.thumbFill") private var thumbFill = true
    @AppStorage(Library.confirmDeleteKey) private var confirmDelete = true
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .system
    let photo: Photo
    @Binding var lines: Lines
    @Binding var showGuide: Bool
    @Binding var showDetected: Bool

    var body: some View {
        @Bindable var library = library
        NavigationStack {
            Form {
                // This photo's view first, then app-wide settings, Appearance last.
                Section {
                    Toggle("Suggested horizon", isOn: $showDetected)
                    Toggle("Guide line", isOn: $showGuide)
                } header: {
                    Text("Level")
                } footer: {
                    Text("Shown in the level tool. The dashed line appears only for confident tilts.")
                }
                Section("View") {
                    Picker("Lines", selection: $lines) { ForEach(Lines.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented)
                    Toggle("Crop grid photos to fill", isOn: $thumbFill)
                }
                Section("This photo") {
                    Button("Use suggested angle") { library.resetToDetected(photo.id) }.disabled(photo.detection == nil)
                    Button("Copy") { library.copyPhotos([photo], kind: .asShown) }
                    if photo.rawCompanion != nil {
                        Button("Copy RAW File") { library.copyPhotos([photo], kind: .raw) }
                    }
                    if !library.savable([photo.id]).isEmpty {
                        Button("Save to Original") {
                            Task {
                                let r = await library.saveToOriginals([photo.id])
                                library.toast = r.failed.isEmpty ? "Saved to original" : "Couldn't save: \(r.failed.first ?? "")"
                            }
                        }
                    }
                    if library.hasBackup(photo) {
                        Button("Restore Original") { library.restoreOriginals([photo.id]) }
                    }
                    Button("History") {
                        library.showSettings = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { library.showActivity = true }
                    }
                    Button("Reset Decision", role: .destructive) { library.resetToOriginal([photo.id]) }
                    Button("Move to Trash", role: .destructive) {
                        library.showSettings = false
                        let id = photo.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { library.requestDelete([id]) }
                    }
                }
                EditorButtonsSection()
                Section {
                    Toggle("Next photo after a decision", isOn: $library.advanceAfterDecision)
                    Toggle("Ask before deleting", isOn: $confirmDelete)
                    Toggle("Pair RAW + JPEG", isOn: $library.pairRaw)
                    Toggle("Reopen the last folder at launch", isOn: $library.reopenLastFolder)
                } header: {
                    Text("General")
                } footer: {
                    Text("Pair RAW + JPEG shows a JPEG and its RAW as one photo.")
                }
                Section {
                    Picker("Review order", selection: $library.reviewOrder) {
                        ForEach(ReviewOrder.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Review order")
                } footer: {
                    Text("Shot order keeps bursts together.")
                }
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { library.showSettings = false } }
            }
        }
        .tint(.primary)
    }
}

/// Settings ▸ Editor buttons: which buttons the editor's top bar shows, and in what order (Edit to reorder).
/// Close, the counter and the settings button always stay; buttons that don't fit go into a ⋯ menu.
private struct EditorButtonsSection: View {
    @AppStorage(PhotoControl.phoneKey) private var raw = PhotoControl.defaultValue(.phone)

    private var chosen: [PhotoControl] { PhotoControl.parse(raw, on: .phone) }
    /// The chosen ones in their order, then the rest.
    private var rows: [PhotoControl] { chosen + PhotoControl.all(on: .phone).filter { !chosen.contains($0) } }

    var body: some View {
        Section {
            ForEach(rows) { c in
                Toggle(isOn: Binding(
                    get: { chosen.contains(c) },
                    set: { on in
                        var list = chosen
                        if on { if !list.contains(c) { list.append(c) } } else { list.removeAll { $0 == c } }
                        raw = PhotoControl.serialize(list)
                    })) {
                    Label(c.title, systemImage: c.symbol)
                }
            }
            .onMove { from, to in
                var order = rows
                order.move(fromOffsets: from, toOffset: to)
                let on = Set(chosen)
                raw = PhotoControl.serialize(order.filter { on.contains($0) })
            }
            Button("Restore Defaults") { raw = PhotoControl.defaultValue(.phone) }
        } header: {
            HStack {
                Text("Editor buttons")
                Spacer()
                EditButton().font(.footnote).textCase(nil)
            }
        } footer: {
            Text("Edit to reorder. Close, the counter and Settings always stay; buttons that don't fit go into ⋯.")
        }
    }
}
