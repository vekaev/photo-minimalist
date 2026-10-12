import AppKit
import SwiftUI

/// The Fixes mode of the preview (like crop mode or the level tool): the photo as shot (upright, no leveling or
/// crop, so zones and rows line up with the file) with the film scan fix, and a ~300 pt panel on the right.
/// Changes show live (debounced ~50 ms in `EditedImage`) and are stored when a control is released: each is one
/// undoable step (`Library.setBandFix`). Hidden unless Settings ▸ Advanced ▸ "Film scan fixes" is on.
struct FixesWorkspace: View {
    @Environment(Library.self) private var library
    let photo: Photo
    let image: CGImage?
    /// The preview's zoom (shared with PhotoView, so ⌘+ / ⌘− / ⌘0 and the reset per photo work here too).
    @Binding var zoom: PreviewZoom

    /// What's on screen and in the panel; stored into the photo on release.
    @State private var draft = BandFixSettings()
    @State private var analysis: BandAnalysis?
    @State private var measuring = false
    @AppStorage("fixesView") private var mode: BandFixView = .after
    @State private var splitX: CGFloat = 0.5
    /// A row selection being dragged (fractions along the band's height axis).
    @State private var rowDrag: ClosedRange<Double>?

    private var applied: Bool { photo.bandFix != nil }
    private var others: [String] { library.targets(for: photo.id).filter { $0 != photo.id } }
    private var portrait: Bool { image.map { $0.height > $0.width } ?? false }

    var body: some View {
        HStack(spacing: 0) {
            canvas
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            Rectangle().fill(Theme.line).frame(width: 1)
            panel.frame(width: 300)
        }
        .onAppear { draft = photo.bandFix ?? BandFixSettings() }
        .onChange(of: photo.id) { draft = photo.bandFix ?? BandFixSettings(); analysis = nil; rowDrag = nil }
        // Undo / redo / remove / revert change the stored fix: follow it.
        .onChange(of: photo.bandFix) { _, stored in draft = stored ?? BandFixSettings() }
        .task(id: analysisKey) {
            measuring = true
            let a = await BandFixStore.shared.analysis(url: photo.url, settings: draft)
            guard !Task.isCancelled else { return }
            analysis = a
            measuring = false
        }
    }

    private var analysisKey: String { photo.url.path + "|" + BandFixStore.settingsKey(draft) }

    private func commit() { library.setBandFix(photo.id, draft) }

    // MARK: Photo

    private var canvas: some View {
        GeometryReader { geo in
            let area = geo.size
            let aspect = image.map { CGFloat($0.width) / CGFloat($0.height) } ?? 1.5
            let w = min(area.width, area.height * aspect)
            let fit = CGSize(width: w, height: w / aspect)
            // Zoomed in (pinch, ⌥-scroll, ⌘+), the frame is bigger than the canvas; two-finger scroll pans
            // (a plain drag still measures rows).
            let frame = zoom.frame(fit: fit, in: area)
            let visible = PreviewZoom.visible(frame, in: area)
            ZStack(alignment: .topLeading) {
                if let image {
                    let before = EditedImage(image: image)
                    let after = EditedImage(image: image, fix: BandFixSource(url: photo.url, settings: draft), fixMaxPixel: 2000)
                    Group {
                        switch mode {
                        case .before: before
                        case .after: after
                        case .split:
                            ZStack(alignment: .topLeading) {
                                before
                                after.mask(alignment: .trailing) { Rectangle().frame(width: frame.width * (1 - splitX)) }
                            }
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
                }
                rowsShade(frame)
                zoneLines(frame)
                if mode == .split { splitHandle(frame, visible: visible) }
            }
            .frame(width: area.width, height: area.height, alignment: .topLeading)  // zoomed-in children are wider than the canvas: keep them anchored
            .clipped()
            .contentShape(Rectangle())
            .coordinateSpace(name: "fixes")
            .background { CanvasEvents { e, p in zoom.handle(e, at: p) } }
            .onChange(of: [fit.width, fit.height, area.width, area.height], initial: true) { zoom.layout(fit: fit, area: area) }
            .overlay(alignment: .bottomTrailing) { ZoomPill(zoom: zoom) { withAnimation(.easeOut(duration: 0.18)) { zoom.reset() } } }
            .animation(.easeOut(duration: 0.2), value: zoom.isZoomed)
            .gesture(rowGesture(frame))
            .overlay(alignment: .top) {
                if mode == .split {
                    HStack {
                        tag("Before")
                        Spacer()
                        tag("After")
                    }
                    .frame(width: visible.width)
                    .padding(.top, visible.minY + 8)
                    .allowsHitTesting(false)
                }
            }
        }
        .background(Theme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
            .padding(.horizontal, 8)
    }

    /// Dashed lines at the inner zone boundaries (zones run along the long side; a portrait is analysed rotated).
    private func zoneLines(_ frame: CGRect) -> some View {
        let edges = [draft.zoneLeft, 1 - draft.zoneRight]
        return Path { p in
            for z in edges {
                if portrait {
                    let y = frame.minY + z * frame.height
                    p.move(to: CGPoint(x: frame.minX, y: y)); p.addLine(to: CGPoint(x: frame.maxX, y: y))
                } else {
                    let x = frame.minX + z * frame.width
                    p.move(to: CGPoint(x: x, y: frame.minY)); p.addLine(to: CGPoint(x: x, y: frame.maxY))
                }
            }
        }
        .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        .shadow(color: .black.opacity(0.5), radius: 1)
        .allowsHitTesting(false)
    }

    /// The measured rows, shaded. In a portrait they're columns (rotated: row t = original x 1 − t).
    @ViewBuilder private func rowsShade(_ frame: CGRect) -> some View {
        if let r = rowDrag ?? draft.rows {
            let rect = portrait
                ? CGRect(x: frame.minX + (1 - r.upperBound) * frame.width, y: frame.minY,
                         width: (r.upperBound - r.lowerBound) * frame.width, height: frame.height)
                : CGRect(x: frame.minX, y: frame.minY + r.lowerBound * frame.height,
                         width: frame.width, height: (r.upperBound - r.lowerBound) * frame.height)
            Rectangle().fill(Color.white.opacity(0.16))
                .overlay(Rectangle().stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    /// Drag up or down on the photo (sideways on a portrait) to choose the rows to measure from.
    private func rowGesture(_ frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("fixes"))
            .onChanged { g in
                func t(_ p: CGPoint) -> Double {
                    portrait ? 1 - min(max((p.x - frame.minX) / frame.width, 0), 1)
                             : min(max((p.y - frame.minY) / frame.height, 0), 1)
                }
                let a = t(g.startLocation), b = t(g.location)
                rowDrag = min(a, b)...max(a, b)
            }
            .onEnded { _ in
                defer { rowDrag = nil }
                guard let r = rowDrag, r.upperBound - r.lowerBound > 0.02 else { return }
                draft.rows = r
                commit()
            }
    }

    private func splitHandle(_ frame: CGRect, visible: CGRect) -> some View {
        let x = frame.minX + splitX * frame.width
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.white).frame(width: 2, height: visible.height).offset(x: x - 1, y: visible.minY)
                .shadow(color: .black.opacity(0.4), radius: 1)
            Circle().fill(.white).frame(width: 26, height: 26)
                .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.black))
                .position(x: x, y: visible.midY)
            Rectangle().fill(Color.white.opacity(0.001)).frame(width: 24, height: visible.height).offset(x: x - 12, y: visible.minY)
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("fixes"))
                        .onChanged { g in splitX = min(max((g.location.x - frame.minX) / frame.width, 0), 1) }
                )
        }
    }

    // MARK: Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fixes").font(.headline)
                        Text(applied ? "Shutter bands · applied" : "Shutter bands · preview, not applied yet")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    BandStatusLines(analysis: analysis, loading: measuring)
                    Picker("View", selection: $mode) {
                        ForEach(BandFixView.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    VStack(alignment: .leading, spacing: 10) {
                        slider("Left strength", \.left, 0...2, step: 0.01) { String(format: "%.0f%%", $0 * 100) }
                        slider("Right strength", \.right, 0...2, step: 0.01) { String(format: "%.0f%%", $0 * 100) }
                        slider("Flatten edge", \.flatten, 0...1, step: 0.01,
                               hint: "0 keeps the frame edge's brightness · 1 matches it to the clean sky inside") { String(format: "%.2f", $0) }
                        slider("Left zone", \.zoneLeft, 0.10...0.40, step: 0.01) { String(format: "%.0f%% of width", $0 * 100) }
                        slider("Right zone", \.zoneRight, 0.05...0.30, step: 0.01) { String(format: "%.0f%% of width", $0 * 100) }
                        slider("Tilt", \.tilt, -0.03...0.03, step: 0.001,
                               hint: "If the band leans, slide until it lines up top to bottom") { String(format: "%+.3f", $0) }
                        Toggle("Correct even if not detected", isOn: Binding(
                            get: { draft.force }, set: { draft.force = $0; commit() }))
                            .toggleStyle(.checkbox)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Measured rows").font(.callout)
                            Spacer()
                            Text(rowsText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                            Button("Auto Rows") { draft.rows = nil; commit() }
                                .controlSize(.small)
                                .disabled(draft.rows == nil)
                        }
                        Text(portrait ? "Drag sideways on the photo to measure only those rows (sky works best)."
                                      : "Drag up or down on the photo to measure only those rows (sky works best).")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Brightness across the frame").font(.callout)
                        BandProfileChart(analysis: analysis)
                    }
                }
                .padding(16)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            VStack(spacing: 10) {
                if !others.isEmpty {
                    Button { library.applyBandFix(library.targets(for: photo.id), settings: draft) } label: {
                        Text("Apply to \(others.count + 1) Selected Photos").frame(maxWidth: .infinity)
                    }
                    .help("Copies these settings to the selected photos; each is measured again, clean ones are left alone")
                }
                HStack(spacing: 8) {
                    Button("Reset") {
                        draft = BandFixSettings()
                        if applied { commit() }
                    }
                    .help("Back to the automatic settings")
                    if applied {
                        Button("Remove Fix") { library.removeBandFix([photo.id]) }
                    } else {
                        Button("Apply Fix") { commit() }
                    }
                    Spacer()
                    Button { library.fixesTool = false } label: {
                        Text("Done").fontWeight(.semibold).padding(.horizontal, 16).frame(height: 30)
                            .foregroundStyle(Theme.ground).background(Color.primary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Close Fixes (Esc)")
                }
            }
            .padding(16)
        }
        .background(Theme.panel)
    }

    private var rowsText: String {
        guard let r = draft.rows else { return "auto" }
        return String(format: "%.0f–%.0f%%", r.lowerBound * 100, r.upperBound * 100)
    }

    private func slider(_ title: String, _ key: WritableKeyPath<BandFixSettings, Double>, _ range: ClosedRange<Double>,
                        step: Double, hint: String? = nil, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(draft[keyPath: key])).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding(
                get: { draft[keyPath: key] },
                set: { draft[keyPath: key] = ($0 / step).rounded() * step }
            ), in: range) { editing in
                if !editing { commit() }
            }
            .controlSize(.small)
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
