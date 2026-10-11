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
    var detection: Detection?
    private(set) var history: [Snapshot] = [Snapshot(decision: .undecided, correction: 0, label: "Original")]
    private(set) var index = 0

    init(id: String, url: URL) {
        self.id = id
        self.url = url
    }

    var current: Snapshot { history[index] }
    var decision: Decision { current.decision }
    var correction: Double { current.correction }
    /// Rotation that export will actually apply.
    var appliedCorrection: Double { decision == .level ? correction : 0 }
    var name: String { url.lastPathComponent }
    var canUndo: Bool { index > 0 }
    var canRedo: Bool { index < history.count - 1 }

    func record(_ decision: Decision, correction: Double, label: String) {
        let next = Snapshot(decision: decision, correction: correction, label: label)
        if next.decision == current.decision, next.correction == current.correction { return }
        history.removeSubrange((index + 1)...)
        history.append(next)
        index = history.count - 1
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
    }

    var saved: Saved { Saved(analyzed: analyzed, detection: detection, history: history, index: index) }

    func restore(_ s: Saved) {
        analyzed = s.analyzed
        detection = s.detection
        if !s.history.isEmpty {
            history = s.history
            index = min(max(s.index, 0), s.history.count - 1)
        }
    }
}
