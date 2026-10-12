import SwiftUI

/// Photos whose header is being read right now, so a row scrolled in twice doesn't read it twice.
@MainActor private var infoInFlight: Set<URL> = []

extension Library {
    /// Reads a photo's camera details once it's on screen: one small header read through the ReadGate
    /// (on-screen priority), then cached in the folder's json. Does nothing when the details are known.
    func fillInfo(_ p: Photo) async {
        guard p.info == nil, !infoInFlight.contains(p.url) else { return }
        let url = p.url, companions = p.companions
        infoInFlight.insert(url)
        defer { infoInFlight.remove(url) }
        await ReadGate.shared.enter(onScreen: true)
        if Task.isCancelled { await ReadGate.shared.leave(); return }
        let info = await Task.detached(priority: .userInitiated) { PhotoInfo.read(url: url, companions: companions) }.value
        await ReadGate.shared.leave()
        guard let info, p.info == nil else { return }
        p.info = info
        saveSoon()
    }

    /// "−0.5° · 4:5", "4:5" (crop only), "−0.5°", or nil when the photo is as shot.
    func editsText(_ p: Photo) -> String? {
        guard p.decision == .level else { return nil }
        var parts: [String] = []
        if abs(p.correction) >= 0.01 { parts.append(Geometry.format(p.correction)) }
        if let c = p.crop {
            let name = Self.cropName(c, aspect: p.analysisAspect)
            parts.append(name.isEmpty ? "crop" : name)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Every detail of a photo as label / value rows, for the Mac's info overlay and the iPhone's info sheet.
struct PhotoInfoCard: View {
    let photo: Photo
    /// Light text for the dark overlay on the photo (Mac); system colors in a sheet (iPhone).
    var onDark = false

    var body: some View {
        let rows = photo.info?.details ?? []
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text(photo.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    .gridCellColumns(2)
            }
            .padding(.bottom, 2)
            if photo.info == nil {
                GridRow { Text("Reading…").foregroundStyle(secondary).gridCellColumns(2) }
            }
            ForEach(rows, id: \.label) { row in
                GridRow {
                    Text(row.label).foregroundStyle(secondary)
                    Text(row.value).monospacedDigit().textSelection(.enabled)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(onDark ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
    }

    private var secondary: AnyShapeStyle { onDark ? AnyShapeStyle(Color.white.opacity(0.6)) : AnyShapeStyle(.secondary) }
}
