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

struct PhotoView: View {
    @Environment(Library.self) private var library
    let photo: Photo

    @AppStorage("gridMode") private var gridMode: GridMode = .fine
    @AppStorage("horizontalOnly") private var horizontalOnly = true
    @AppStorage("showDetected") private var showDetected = false
    @AppStorage("showGuide") private var showGuide = true
    @AppStorage("showLoupes") private var showLoupes = true
    @AppStorage("compareMode") private var compare: CompareMode = .off
    @AppStorage("overlayOpacity") private var overlayOpacity = 0.5

    @State private var image: CGImage?
    @State private var showOriginal = false
    @State private var preview: Double?
    @State private var drawStart: CGPoint?
    @State private var drawEnd: CGPoint?
    @State private var firstPoint: CGPoint?
    @State private var guideY: CGFloat = 0.5
    @State private var splitX: CGFloat = 0.5
    @FocusState private var focused: Bool

    /// Rotation currently on screen (counter-clockwise positive).
    private var shown: Double {
        if showOriginal { return 0 }
        if let preview { return preview }
        return photo.appliedCorrection
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            viewBar
            HStack(spacing: 0) {
                VStack(spacing: 10) {
                    if compare == .sideBySide && !showOriginal {
                        HStack(spacing: 10) {
                            pane(rotation: 0, interactive: false, caption: "Before")
                            pane(rotation: shown, interactive: true, caption: "After")
                        }
                    } else {
                        pane(rotation: shown, interactive: true, caption: nil)
                    }
                    StraightenRuler(
                        value: preview ?? photo.correction,
                        onChange: { preview = $0 },
                        onCommit: { v in library.setCorrection(photo.id, v); preview = nil }
                    )
                    keyLegend
                }
                .padding(14)
                sidePanel
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onChange(of: photo.id) { firstPoint = nil; guideY = 0.5 }
        .onKeyPress(phases: [.down, .repeat, .up]) { handle($0) }
        .task(id: photo.url) {
            image = await ImageCache.shared.image(for: photo.url, maxPixel: 420)
            image = await ImageCache.shared.image(for: photo.url, maxPixel: 3000)
        }
    }

    // MARK: Bars

    private var topBar: some View {
        let position = (library.navigation.firstIndex(of: photo.id) ?? 0) + 1
        return HStack(spacing: 12) {
            Button { library.closePhoto() } label: { Image(systemName: "square.grid.2x2") }
                .help("Back to grid (Esc)")
            VStack(alignment: .leading, spacing: 1) {
                Text(photo.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("\(position) of \(library.navigation.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            Button { library.step(-1) } label: { Image(systemName: "chevron.left") }.help("Previous (←)")
            Button { library.step(1) } label: { Image(systemName: "chevron.right") }.help("Next (→)")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.panel)
    }

    private var viewBar: some View {
        FlowRow(spacing: 14) {
            Picker("Lines", selection: $gridMode) {
                ForEach(GridMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize().help("Line density (G)")
            Toggle("Horizontal only", isOn: $horizontalOnly).fixedSize()
            Toggle("Guide", isOn: $showGuide).fixedSize().help("A line you drag onto the horizon (T)")
            Toggle("Loupes", isOn: $showLoupes).fixedSize().help("Magnify both ends of the guide line")
            Toggle("Detected", isOn: $showDetected).fixedSize().help("Show the detected horizon (H)")
            HStack(spacing: 8) {
                Picker("Compare", selection: $compare) {
                    ForEach(CompareMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize().help("Before / after (C)")
                if compare == .overlay {
                    Slider(value: $overlayOpacity, in: 0...1).frame(width: 90).help("How much of the original shows through")
                }
            }
        }
        .toggleStyle(.checkbox)
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
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
    private func photoLayer(_ fit: CGSize, rotation: Double, area: CGSize) -> some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
                    .rotationEffect(.degrees(-rotation))
            }
        }
        .frame(width: area.width, height: area.height)
    }

    private func pane(rotation: Double, interactive: Bool, caption: String?) -> some View {
        GeometryReader { geo in
            let area = geo.size
            let aspect = image.map { CGFloat($0.width) / CGFloat($0.height) } ?? 1.5
            let fit = fitted(aspect: aspect, in: area)
            let scale = Geometry.cropScale(width: fit.width, height: fit.height, degrees: rotation)
            let cropping = rotation != 0
            let frame = centered(cropping ? CGSize(width: fit.width * scale, height: fit.height * scale) : fit, in: area)
            let guidePoint = frame.minY + guideY * frame.height
            let comparing = interactive && !showOriginal

            ZStack(alignment: .topLeading) {
                photoLayer(fit, rotation: rotation, area: area)

                if comparing && compare == .overlay {
                    photoLayer(fit, rotation: 0, area: area).opacity(overlayOpacity)
                }
                if comparing && compare == .split {
                    photoLayer(fit, rotation: 0, area: area)
                        .mask(alignment: .leading) { Rectangle().frame(width: splitX * area.width) }
                }

                if cropping {
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: area))
                        p.addRect(frame)
                    }
                    .fill(Theme.ground.opacity(0.75), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    Rectangle().stroke(.white.opacity(0.8), lineWidth: 1)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .allowsHitTesting(false)
                }

                GridOverlay(mode: gridMode, horizontalOnly: horizontalOnly)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)

                if showDetected, let d = photo.detection {
                    HorizonLine(degrees: d.angle + rotation)
                        .frame(width: fit.width, height: fit.height)
                        .offset(x: (area.width - fit.width) / 2, y: (area.height - fit.height) / 2)
                }

                if interactive {
                    if comparing && compare == .split { splitHandle(area: area) }
                    if showGuide { guideLine(frame: frame, y: guidePoint) }
                    drawingLayer
                }
            }
            .frame(width: area.width, height: area.height)
            .clipped()
            .contentShape(Rectangle())
            .coordinateSpace(name: "canvas")
            .gesture(interactive ? drawGesture : nil)
            .simultaneousGesture(interactive ? SpatialTapGesture(coordinateSpace: .named("canvas")).onEnded { tap($0.location) } : nil)
            .overlay(alignment: guideY > 0.62 ? .top : .bottom) {
                if interactive && showGuide && showLoupes && image != nil {
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
                if showOriginal { badge("Original", .white) }
                else if photo.decision == .keep && interactive { badge("Kept as shot: won't be leveled. Press L to level it.", Theme.keep) }
                else if let caption { badge(caption, .white) }
            }
            .overlay(alignment: .topTrailing) {
                if interactive, !showOriginal, compare == .split {
                    Text("Before | After").font(.caption).padding(6)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4)).padding(10)
                }
            }
        }
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
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

    // MARK: Guide line and loupes

    private static let guideColor = Color(red: 0.31, green: 0.82, blue: 1.0)

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
                )
                .help("Drag onto the horizon")
        }
    }

    private func loupe(fit: CGSize, rotation: Double, area: CGSize, focus: CGPoint, label: String) -> some View {
        let size = CGSize(width: 200, height: 120)
        let zoom: CGFloat = 5
        return photoLayer(fit, rotation: rotation, area: area)
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

    // MARK: Drawing a line or clicking two points

    @ViewBuilder private var drawingLayer: some View {
        if let a = drawStart, let b = drawEnd {
            Path { p in p.move(to: a); p.addLine(to: b) }.stroke(Theme.accent, lineWidth: 2)
            hint("Level this line · " + Geometry.format(-Geometry.lineTilt(from: a, to: b)), at: b)
        }
        if let a = firstPoint {
            Circle().stroke(Theme.accent, lineWidth: 2).frame(width: 14, height: 14).position(a)
            Circle().fill(Theme.accent).frame(width: 4, height: 4).position(a)
            hint("Now click a second point on the horizon · Esc to cancel", at: a)
        }
    }

    private func hint(_ text: String, at p: CGPoint) -> some View {
        Text(text).font(.caption).padding(6)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
            .position(x: p.x, y: p.y - 22)
            .allowsHitTesting(false)
    }

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("canvas"))
            .onChanged { v in firstPoint = nil; drawStart = v.startLocation; drawEnd = v.location }
            .onEnded { v in
                level(from: v.startLocation, to: v.location, label: "Drawn line")
                drawStart = nil; drawEnd = nil
            }
    }

    private func tap(_ p: CGPoint) {
        focused = true
        guard let a = firstPoint else { firstPoint = p; return }
        firstPoint = nil
        guard hypot(p.x - a.x, p.y - a.y) > 10 else { return }
        level(from: a, to: p, label: "Two points")
    }

    private func level(from a: CGPoint, to b: CGPoint, label: String) {
        let next = shown - Geometry.lineTilt(from: a, to: b)
        library.setCorrection(photo.id, next, label: label + " " + Geometry.format(next))
    }

    // MARK: Legend and side panel

    private var keyLegend: some View {
        let keys: [(String, String)] = [
            ("L", "Level"), ("K", "Keep as shot"), ("U", "Undecided"), ("← →", "Prev / next"),
            ("[ ]", "±0.1°"), ("⇧[ ⇧]", "±1°"), ("Click ×2", "Level through 2 points"), ("Drag", "Level a line"),
            ("R", "Detected"), ("0", "Original"), ("G", "Lines"), ("T", "Guide"), ("C", "Compare"),
            ("Space", "Hold: original"), ("⌘Z", "Undo"), ("Esc", "Grid view"),
        ]
        return FlowRow(spacing: 12) {
            ForEach(keys, id: \.0) { k in
                HStack(spacing: 5) { Keycap(key: k.0); Text(k.1) }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Decision") {
                    HStack(spacing: 6) {
                        decisionButton(.level, "L", Theme.accent)
                        decisionButton(.keep, "K", Theme.keep)
                        decisionButton(.undecided, "U", Color(white: 0.45))
                    }
                    if let d = photo.detection {
                        Text("Detected tilt \(Geometry.format(d.angle)) · \(Int(d.confidence * 100))% confident")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(photo.analyzed ? "No tilt found. Click two points on the horizon to level it." : "Analyzing…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                section("Correction") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Geometry.format(preview ?? photo.correction))
                            .font(.system(size: 30, weight: .medium, design: .monospaced))
                        if photo.decision != .level {
                            Text("not applied").foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 6) {
                        nudge("−1°", -1); nudge("−0.1°", -0.1); nudge("+0.1°", 0.1); nudge("+1°", 1)
                    }
                    HStack {
                        Button("Use detected") { library.resetToDetected(photo.id) }.disabled(photo.detection == nil)
                        Button("Reset to original") { library.resetToOriginal([photo.id]) }
                    }
                }

                section("History") {
                    Text("Click any step to go back to it. Originals are never modified.")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(spacing: 2) {
                        ForEach(Array(photo.history.enumerated()), id: \.offset) { i, step in
                            Button { library.jump(photo.id, to: i) } label: {
                                HStack {
                                    Text(step.label)
                                    Spacer()
                                    Text(step.date, style: .time).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .foregroundStyle(i > photo.index ? .secondary : .primary)
                                .background(i == photo.index ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(i == photo.index ? Theme.accent : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(18)
        }
        .frame(width: 300)
        .background(Theme.panel)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.medium)).foregroundStyle(.secondary).tracking(0.6)
            content()
        }
    }

    private func decisionButton(_ d: Decision, _ key: String, _ color: Color) -> some View {
        let on = photo.decision == d
        return Button { decide(d) } label: {
            VStack(spacing: 2) {
                Text(d == .keep ? "Keep" : d.label).fontWeight(on ? .semibold : .regular)
                Text(key).font(.system(size: 10, design: .monospaced)).opacity(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(on ? Color.black : .primary)
            .background(on ? color : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? color : Theme.line, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func nudge(_ title: String, _ delta: Double) -> some View {
        Button(title) { library.nudge(photo.id, by: delta) }
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity)
    }

    // MARK: Keys

    private func decide(_ d: Decision) {
        library.decide([photo.id], d)
        if library.advanceAfterDecision { library.step(1) }
    }

    private func cycle<T: CaseIterable & Equatable>(_ value: T) -> T {
        let all = Array(T.allCases)
        let i = all.firstIndex(of: value) ?? all.startIndex
        return all[(i + 1) % all.count]
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .space {
            showOriginal = press.phase != .up
            return .handled
        }
        guard press.phase != .up else { return .ignored }
        if press.modifiers.contains(.command) { return .ignored }
        switch press.key {
        case .leftArrow: library.step(-1); return .handled
        case .rightArrow: library.step(1); return .handled
        case .escape:
            if firstPoint != nil { firstPoint = nil } else { library.closePhoto() }
            return .handled
        default: break
        }
        let repeatable: Set<String> = ["[", "]", "{", "}"]
        if press.phase == .repeat && !repeatable.contains(press.characters) { return .handled }
        switch press.characters {
        case "l", "L": decide(.level)
        case "k", "K": decide(.keep)
        case "u", "U": decide(.undecided)
        case "[": library.nudge(photo.id, by: 0.1)
        case "]": library.nudge(photo.id, by: -0.1)
        case "{": library.nudge(photo.id, by: 1)
        case "}": library.nudge(photo.id, by: -1)
        case "r", "R": library.resetToDetected(photo.id)
        case "0": library.resetToOriginal([photo.id])
        case "g", "G": gridMode = cycle(gridMode)
        case "t", "T": showGuide.toggle()
        case "c", "C": compare = cycle(compare)
        case "h", "H": showDetected.toggle()
        default: return .ignored
        }
        return .handled
    }
}

/// Wraps children onto new lines when they run out of width.
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
