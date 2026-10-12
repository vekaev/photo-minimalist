import SwiftUI

/// Finder-like columns shown to the right of the name when the list has the whole window (preview hidden).
enum InfoColumn: CaseIterable, Identifiable {
    case date, camera, exposure, size, edits
    var id: Self { self }

    var title: String {
        switch self {
        case .date: return "Date taken"
        case .camera: return "Camera · lens"
        case .exposure: return "Exposure"
        case .size: return "Size"
        case .edits: return "Edits"
        }
    }

    var width: CGFloat {
        switch self {
        case .date: return 130
        case .camera: return 170
        case .exposure: return 190
        case .size: return 200
        case .edits: return 90
        }
    }

    /// Numbers line up on the right, names on the left.
    var alignment: Alignment { self == .camera ? .leading : .trailing }

    static let spacing: CGFloat = 16
    /// Thumbnail, name and status never get narrower than this.
    static let nameMinimum: CGFloat = 280
    /// Kept first as the window narrows: date and edits, then exposure, size, and camera last.
    private static let keepOrder: [InfoColumn] = [.date, .edits, .exposure, .size, .camera]

    /// The columns that fit next to the name in a list `width` points wide, in display order.
    static func fitting(_ width: CGFloat) -> [InfoColumn] {
        var room = width - 16 - 12 - nameMinimum   // list and row padding
        var kept: Set<InfoColumn> = []
        for c in keepOrder {
            let need = c.width + spacing
            if room >= need { kept.insert(c); room -= need } else { break }
        }
        return allCases.filter(kept.contains)
    }

    @MainActor func text(_ p: Photo, library: Library) -> String {
        let info = p.info
        switch self {
        case .date: return info?.taken?.formatted(Self.dateStyle) ?? "—"
        case .camera: return info?.cameraLine ?? "—"
        case .exposure: return info?.exposureLine ?? "—"
        case .size: return info?.sizeLine ?? "—"
        case .edits: return library.editsText(p) ?? "—"
        }
    }

    /// "Oct 3, 2026, 14:22" (camera wall-clock time, see `PhotoInfo.taken`).
    private static let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: TimeZone(identifier: "UTC")!)
}

/// The thin header above the columns: "Name … Date taken  Camera · lens  Exposure  Size  Edits".
struct InfoColumnHeader: View {
    let columns: [InfoColumn]

    var body: some View {
        HStack(spacing: InfoColumn.spacing) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 58 + 10)
            ForEach(columns) { c in
                Text(c.title).frame(width: c.width, alignment: c.alignment)
            }
        }
        .font(.caption2.weight(.medium)).textCase(.uppercase).tracking(0.4)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 8 + 6)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// One row's values for `columns`.
struct InfoColumnCells: View {
    @Environment(Library.self) private var library
    let photo: Photo
    let columns: [InfoColumn]

    var body: some View {
        HStack(spacing: InfoColumn.spacing) {
            ForEach(columns) { c in
                let value = c.text(photo, library: library)
                Text(value)
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(value == "—" ? .tertiary : .secondary)
                    .lineLimit(1).truncationMode(c == .camera ? .tail : .head)
                    .frame(width: c.width, alignment: c.alignment)
                    .help(value == "—" ? "" : value)
            }
        }
    }
}

/// The preview's "Info" (I): every detail on a dark card, bottom-left over the photo.
struct InfoOverlay: View {
    @Environment(Library.self) private var library
    let photo: Photo

    var body: some View {
        PhotoInfoCard(photo: photo, onDark: true)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: 320, alignment: .leading)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
            .padding(12)
            .task(id: photo.url) { await library.fillInfo(photo) }
    }
}
