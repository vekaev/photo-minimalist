import SwiftUI

// Crop studio: save several crops of a photo as versions, compare them side by side, choose one.
// The chosen version becomes the applied crop; export, save and copy keep using that.

extension CropRatio {
    /// The ratio button (and flip) that produced a version's label, so loading it keeps the same lock.
    static func matching(_ label: String) -> (ratio: CropRatio, flipped: Bool)? {
        for r in allCases {
            for flipped in [false, true] where r.label(flipped: flipped) == label { return (r, flipped) }
        }
        return nil
    }
}

/// One version, exactly as it will be saved (final crop only, no matte or guides).
struct CropVersionThumb: View {
    let image: CGImage?
    let rotation: Double
    let version: CropVersion
    let height: CGFloat
    var fix: BandFixSource? = nil
    var number: Int?
    var chosen = false
    var current = false

    var body: some View {
        let aspect = Geometry.finalAspect(image.map { CGFloat($0.width) / CGFloat($0.height) } ?? 1.5, crop: version.rect)
        ZStack {
            Color.primary.opacity(0.06)
            if let image { EditedImage(image: image, rotation: rotation, crop: version.rect, fix: fix) }
        }
        .frame(width: height * aspect, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(current ? Color.primary : .clear, lineWidth: 1.5).padding(-2.5))
        .overlay(alignment: .topTrailing) {
            if chosen {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: height > 120 ? 18 : 12, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black, .white)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .padding(height > 120 ? 8 : 3)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let number, height <= 120 {
                Text("\(number)").font(.system(size: 9, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                    .padding(3)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The thin strip under the photo in crop mode: "+ Version", the saved versions, "Compare".
struct CropVersionStrip: View {
    @Environment(Library.self) private var library
    let photo: Photo
    let image: CGImage?
    /// The crop being edited, to outline the version it came from.
    let draft: CGRect
    var height: CGFloat = 46
    let onAdd: () -> Void
    let onLoad: (CropVersion) -> Void
    let onCompare: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onAdd) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Version")
                    #if os(macOS)
                    Text("V").foregroundStyle(.tertiary)
                    #endif
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12).frame(height: 30)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .help("Save this crop as a version (V) and keep editing")
            #endif
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(photo.cropVersions.enumerated()), id: \.element.id) { i, v in
                        CropVersionThumb(image: image, rotation: photo.correction, version: v, height: height, fix: photo.bandFixSource, number: i + 1,
                                         chosen: photo.chosenVersion?.id == v.id, current: Library.sameRect(v.rect, draft))
                            .onTapGesture { onLoad(v) }
                            .contextMenu {
                                Button(role: .destructive) { library.removeCropVersion(photo.id, v.id) } label: {
                                    Label("Delete Version \(i + 1)", systemImage: "trash")
                                }
                            }
                            .accessibilityLabel("Version \(i + 1) \(v.ratio)")
                            #if os(macOS)
                            .help("Version \(i + 1)\(v.ratio.isEmpty ? "" : " · " + v.ratio): click to edit it, right-click to delete")
                            #endif
                    }
                }
                .padding(.vertical, 4).padding(.horizontal, 3)
            }
            .frame(height: height + 8)
            if !photo.cropVersions.isEmpty {
                Button(action: onCompare) {
                    HStack(spacing: 4) {
                        Text("Compare")
                        #if os(macOS)
                        Text("⇧C").foregroundStyle(.tertiary)
                        #endif
                    }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12).frame(height: 30)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A contact sheet of every version, large and the same height (a Lightroom-style survey).
/// Click one (or press 1–9 on the Mac) to make it the applied crop.
struct CropStudio: View {
    let photo: Photo
    let image: CGImage?
    let onChoose: (CropVersion) -> Void
    let onClose: () -> Void
    #if os(macOS)
    @FocusState private var focused: Bool
    #endif

    private let gap: CGFloat = 14, caption: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compare crops").font(.headline)
                    #if os(macOS)
                    Text("Click one, or press its number, to use it.").font(.caption).foregroundStyle(.secondary)
                    #else
                    Text("Tap one to use it.").font(.caption).foregroundStyle(.secondary)
                    #endif
                }
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            GeometryReader { geo in
                let plan = layout(in: CGSize(width: geo.size.width - 40, height: geo.size.height - 32))
                VStack(spacing: gap) {
                    ForEach(Array(plan.rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(row, id: \.self) { i in tile(i, height: plan.height) }
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        #if os(macOS)
        .frame(minWidth: 820, idealWidth: 1100, minHeight: 520, idealHeight: 700)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress { press in
            guard let n = Int(press.characters), n >= 1, n <= min(9, photo.cropVersions.count) else { return .ignored }
            onChoose(photo.cropVersions[n - 1])
            return .handled
        }
        #endif
    }

    private func tile(_ i: Int, height: CGFloat) -> some View {
        let v = photo.cropVersions[i]
        let chosen = photo.chosenVersion?.id == v.id
        return VStack(spacing: 6) {
            CropVersionThumb(image: image, rotation: photo.correction, version: v, height: height, fix: photo.bandFixSource, chosen: chosen)
            HStack(spacing: 6) {
                Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary)
                Text(v.ratio.isEmpty ? "Free" : v.ratio)
                if chosen { Text("· in use").foregroundStyle(.secondary) }
            }
            .font(.caption.weight(chosen ? .semibold : .regular))
            .frame(height: caption - 6)
        }
        .contentShape(Rectangle())
        .onTapGesture { onChoose(v) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Version \(i + 1) \(v.ratio)\(chosen ? ", in use" : "")")
        .accessibilityAddTraits(.isButton)
    }

    /// Rows and a shared tile height: tries every row count and keeps the one with the biggest tiles.
    private func layout(in size: CGSize) -> (rows: [[Int]], height: CGFloat) {
        let n = photo.cropVersions.count
        guard n > 0, size.width > 0, size.height > 0 else { return ([], 0) }
        let imageAspect = image.map { CGFloat($0.width) / CGFloat($0.height) } ?? 1.5
        let aspects = photo.cropVersions.map { Geometry.finalAspect(imageAspect, crop: $0.rect) }
        var best: (rows: [[Int]], height: CGFloat) = ([Array(0..<n)], 0)
        for r in 1...n {
            let per = Int((Double(n) / Double(r)).rounded(.up))
            let rows = stride(from: 0, to: n, by: per).map { Array($0..<min($0 + per, n)) }
            var h = (size.height - CGFloat(rows.count - 1) * gap) / CGFloat(rows.count) - caption
            for row in rows {
                let sum = row.reduce(0) { $0 + aspects[$1] }
                h = min(h, (size.width - CGFloat(row.count - 1) * gap) / sum)
            }
            if h > best.height { best = (rows, h) }
        }
        best.height = max(best.height, 20)
        return best
    }
}
