import Foundation
import Observation

enum Decision: String, Codable {
    case undecided, level, keep

    var label: String {
        switch self {
        case .undecided: return "Undecided"
        case .level: return "Level"
        case .keep: return "Keep as shot"
        }
    }
}

/// One step in a photo's edit history. The correction is kept even when the decision is
/// "keep" or "undecided", so switching back to "level" restores it.
struct Snapshot: Codable, Equatable {
    var decision: Decision
    var correction: Double
    var label: String
    var date = Date()
    /// 0…1 rectangle in the leveled frame (origin top-left); nil = no crop.
    var crop: CGRect?
}

/// What the photo list shows. Everything starts in "To review": nothing is decided for you.
enum Filter: String, CaseIterable, Identifiable {
    case review, leveled, kept, favorites, all
    /// Photos with two or more crop versions: reached from the ⋯ menu, not a tab.
    case crops
    /// The tabs: All · Tilted · Edited · ♥. `.kept` (photos dismissed as shot) and `.crops` stay reachable
    /// in code but aren't tabs: a kept photo simply leaves Tilted.
    static var allCases: [Filter] { [.all, .review, .leveled, .favorites] }
    var id: String { rawValue }
    var label: String {
        switch self {
        case .review: return "Tilted"
        case .leveled: return "Edited"
        case .kept: return "Kept"
        case .favorites: return "Favorites"
        case .all: return "All"
        case .crops: return "Crop versions"
        }
    }
}

/// One saved try at cropping a photo ("+ Version"). The applied crop stays `Snapshot.crop`; choosing a
/// version copies its rect there.
struct CropVersion: Codable, Equatable, Identifiable {
    var id = UUID()
    /// 0…1 rectangle in the leveled frame, like `Snapshot.crop`.
    var rect: CGRect
    /// "4:5", "Free", "Original"…
    var ratio: String
    var created = Date()
}

/// How Review is ordered.
enum ReviewOrder: String, CaseIterable, Identifiable {
    /// File name order, which is capture order on cameras: bursts and scenes stay together.
    case shot
    /// Likely tilts, then maybes, biggest first, then the rest, each under a heading.
    case tilt
    var id: String { rawValue }
    var label: String { self == .shot ? "Shot order" : "Biggest tilts first" }
}

/// A run of photos under an optional heading ("Looks tilted · 213").
struct PhotoSection: Identifiable {
    let id: String
    let title: String?
    let photos: [Photo]
}

enum Status: String, CaseIterable, Identifiable {
    case needsReview, level, keep, alreadyLevel, noTilt, pending
    var id: String { rawValue }

    var label: String {
        switch self {
        case .needsReview: return "Needs review"
        case .level: return "Will be leveled"
        case .keep: return "Kept as shot"
        case .alreadyLevel: return "Already level"
        case .noTilt: return "No tilt found"
        case .pending: return "Analyzing"
        }
    }
}

@Observable
final class Photo: Identifiable {
    let id: String
    let url: URL
    var analyzed = false
    /// Rotation already written into the file by "Save to original" (the untouched file is in the backup folder).
    var savedCorrection = 0.0
    /// Which detector version produced `detection`; older results are re-checked in the background.
    var analysisVersion = 0
    var detection: Detection?
    private(set) var history: [Snapshot] = [Snapshot(decision: .undecided, correction: 0, label: "Original")]
    private(set) var index = 0

    /// RAW files paired with this JPEG (same name, same folder). Decisions apply to the pair.
    let companions: [URL]

    init(id: String, url: URL, companions: [URL] = []) {
        self.id = id
        self.url = url
        self.companions = companions
    }

    var current: Snapshot { history[index] }
    var decision: Decision { current.decision }
    var correction: Double { current.correction }
    /// Rotation that export will actually apply.
    var appliedCorrection: Double { decision == .level ? correction : 0 }
    var crop: CGRect? { current.crop }
    /// The crop that export and the preview use (only once the photo is marked to be edited).
    var appliedCrop: CGRect? { decision == .level ? current.crop : nil }
    /// Anything to write: a rotation or a crop.
    var hasEdits: Bool { decision == .level && (abs(correction) >= 0.01 || current.crop != nil) }
    /// Width / height of the photo as last loaded (for naming crop ratios); 3:2 until known.
    var analysisAspect: CGFloat = 1.5
    /// The last "Save to original" included a crop, so the file is no longer the full frame.
    var savedHadCrop = false
    /// Marked with ♥ (F). On the Mac the file also gets Finder's Red tag.
    var favorite = false
    /// Crops tried for this photo, oldest first.
    var cropVersions: [CropVersion] = []
    /// The version last chosen in the studio (the applied crop is still `crop`).
    var chosenVersionID: UUID?
    /// Camera details and file sizes from the file's header (`Core/PhotoInfo.swift`), read lazily once the photo
    /// is on screen (or during the background check) and cached in the folder's json.
    var info: PhotoInfo?
    /// The version that matches the current crop, preferring the chosen one.
    var chosenVersion: CropVersion? {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let applied = crop ?? full
        func same(_ v: CropVersion) -> Bool {
            abs(v.rect.minX - applied.minX) < 0.002 && abs(v.rect.minY - applied.minY) < 0.002
                && abs(v.rect.width - applied.width) < 0.002 && abs(v.rect.height - applied.height) < 0.002
        }
        return cropVersions.first { $0.id == chosenVersionID && same($0) } ?? cropVersions.first(where: same)
    }
    var name: String { url.lastPathComponent }
    /// The RAW twin, whose embedded preview loads faster than a big JPEG.
    var rawCompanion: URL? { companions.first(where: ImageLoader.isRaw) }
    /// "RAF" for a JPEG that has a RAF next to it.
    var companionTag: String? {
        companions.isEmpty ? nil : companions.map { $0.pathExtension.uppercased() }.joined(separator: " ")
    }
    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index < history.count - 1 }

    func record(_ decision: Decision, correction: Double, label: String, crop: CGRect?? = nil) {
        let next = Snapshot(decision: decision, correction: correction, label: label, crop: crop ?? current.crop)
        if next.decision == current.decision, next.correction == current.correction, next.crop == current.crop { return }
        history.removeSubrange((index + 1)...)
        history.append(next)
        index = history.count - 1
    }

    /// After writing into the file (or restoring it): the file is the new starting point.
    func startFresh(label: String) {
        history = [Snapshot(decision: .undecided, correction: 0, label: label)]
        index = 0
        detection = nil
        analyzed = false
        info = nil   // the file was rewritten: new size (and pixels, if cropped)
    }

    func undo() { if canUndo { index -= 1 } }
    func redo() { if canRedo { index += 1 } }
    func jump(to i: Int) { if history.indices.contains(i) { index = i } }

    // MARK: Persistence

    struct Saved: Codable {
        var analyzed: Bool
        var detection: Detection?
        var history: [Snapshot]
        var index: Int
        var analysisVersion: Int?
        var savedCorrection: Double?
        var savedHadCrop: Bool?
        var favorite: Bool?
        var cropVersions: [CropVersion]?
        var chosenVersionID: UUID?
        var info: PhotoInfo?
    }

    var saved: Saved { Saved(analyzed: analyzed, detection: detection, history: history, index: index,
                             analysisVersion: analysisVersion, savedCorrection: savedCorrection == 0 ? nil : savedCorrection,
                             savedHadCrop: savedHadCrop ? true : nil, favorite: favorite ? true : nil,
                             cropVersions: cropVersions.isEmpty ? nil : cropVersions, chosenVersionID: chosenVersionID,
                             info: info) }

    func restore(_ s: Saved) {
        analyzed = s.analyzed
        detection = s.detection
        analysisVersion = s.analysisVersion ?? 1
        savedCorrection = s.savedCorrection ?? 0
        savedHadCrop = s.savedHadCrop ?? false
        favorite = s.favorite ?? false
        cropVersions = s.cropVersions ?? []
        chosenVersionID = s.chosenVersionID
        info = s.info ?? info
        if !s.history.isEmpty {
            history = s.history
            index = min(max(s.index, 0), s.history.count - 1)
        }
    }
}
