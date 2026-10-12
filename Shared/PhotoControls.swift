import Foundation

/// Every action the photo preview can offer as a button, for the customizable control bar (Mac: the preview's
/// top row, set up in "Customize Controls…"; iPhone: the editor's top bar, set up in Settings ▸ Editor buttons).
/// The enum is just the catalogue (id, title, symbol, shortcut hint); each view runs the action with its own
/// existing functions (`PhotoView.perform`, `EditorView.perform`). Keyboard shortcuts work whether or not a
/// control is in the bar.
enum PhotoControl: String, CaseIterable, Identifiable {
    case level, crop, favorite, original, info, history, compare, copy, save, export, trash, photos, undo, viewOptions
    /// Film scan fixes (shutter bands): only while Settings ▸ Advanced ▸ "Film scan fixes" is on; never a default.
    case fixes

    enum Platform { case mac, phone }

    var id: String { rawValue }

    /// Full name, for menus, tooltips and the customize sheet.
    var title: String {
        switch self {
        case .level: return "Level Tool"
        case .crop: return "Crop"
        case .favorite: return "Favorite"
        case .original: return "Original ⇄ Result"
        case .info: return "Info"
        case .history: return "History"
        case .compare: return "Compare"
        case .copy: return "Copy"
        case .save: return "Save to Original"
        case .export: return "Export…"
        case .trash: return "Move to Trash"
        case .photos: return "Add to Photos"
        case .undo: return "Undo"
        case .viewOptions: return "View Options"
        case .fixes: return "Fixes…"
        }
    }

    /// One word, shown next to the icon when "Show labels" is on.
    var shortTitle: String {
        switch self {
        case .level: return "Level"
        case .original: return "Original"
        case .save: return "Save"
        case .export: return "Export"
        case .trash: return "Trash"
        case .photos: return "Photos"
        case .viewOptions: return "View"
        case .fixes: return "Fixes"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .level: return "level"
        case .crop: return "crop"
        case .favorite: return "heart"
        case .original: return "eye"
        case .info: return "info.circle"
        case .history: return "clock.arrow.circlepath"
        case .compare: return "square.split.2x1"
        case .copy: return "doc.on.doc"
        case .save: return "square.and.arrow.down"
        case .export: return "square.and.arrow.up"
        case .trash: return "trash"
        case .photos: return "photo.badge.plus"
        case .undo: return "arrow.uturn.backward"
        case .viewOptions: return "slider.horizontal.3"
        case .fixes: return "wand.and.rays"
        }
    }

    /// The Mac keyboard shortcut, for tooltips (nil: no shortcut).
    var shortcut: String? {
        switch self {
        case .level: return "R"
        case .crop: return "C"
        case .favorite: return "F"
        case .original: return "Space"
        case .info: return "I"
        case .copy: return "⌘C"
        case .save: return "⌘S"
        case .export: return "⌘E"
        case .trash: return "⌫"
        case .undo: return "⌘Z"
        case .viewOptions: return "S"
        case .history, .compare, .photos, .fixes: return nil
        }
    }

    /// iPhone: Info is the "3 / 120 ⓘ" counter (always there), View options is the settings button (always
    /// there, it's where the bar is customized), compare isn't built, export works on the whole folder from the grid.
    func available(on platform: Platform) -> Bool {
        // Film scan fixes are Mac-only (the owner's choice), and only while Settings ▸ Advanced has them on.
        if self == .fixes { return platform == .mac && UserDefaults.standard.bool(forKey: "labFixes") }
        switch platform {
        case .mac: return true
        case .phone: return ![.info, .viewOptions, .compare, .export].contains(self)
        }
    }

    static func all(on platform: Platform) -> [PhotoControl] { allCases.filter { $0.available(on: platform) } }

    // MARK: Storage: a comma-separated id list in UserDefaults

    static let macKey = "photoControls"
    static let macLabelsKey = "photoControlsLabels"
    static let phoneKey = "ios.photoControls"

    static let macDefault: [PhotoControl] = [.level, .crop, .favorite, .original, .info, .history, .viewOptions]
    /// What the iPhone editor showed before it was customizable.
    static let phoneDefault: [PhotoControl] = [.original, .favorite, .undo, .crop, .level]

    static func defaultValue(_ platform: Platform) -> String { serialize(platform == .mac ? macDefault : phoneDefault) }

    /// Unknown ids and duplicates are dropped, so an older or newer list never breaks the bar.
    static func parse(_ raw: String, on platform: Platform) -> [PhotoControl] {
        var seen = Set<PhotoControl>()
        return raw.split(separator: ",").compactMap { PhotoControl(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0.available(on: platform) && seen.insert($0).inserted }
    }

    static func serialize(_ list: [PhotoControl]) -> String { list.map(\.rawValue).joined(separator: ",") }

    /// How many controls fit in `width` before the rest go into the trailing overflow menu.
    static func fitting(_ widths: [Double], in width: Double, spacing: Double, overflowWidth: Double) -> Int {
        let all = widths.reduce(0, +) + spacing * Double(max(widths.count - 1, 0))
        if all <= width { return widths.count }
        var used = overflowWidth
        for (i, w) in widths.enumerated() {
            if used + spacing + w > width { return i }
            used += spacing + w
        }
        return widths.count
    }
}
