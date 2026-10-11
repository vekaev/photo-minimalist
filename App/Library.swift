import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class Library {
    var folder: URL?
    var photos: [Photo] = []
    private var byID: [String: Photo] = [:]

    var filter: Status = .needsReview
    var selection: Set<String> = []
    /// Photo shown in the single-photo view; nil shows the grid.
    var openedID: String?
    /// Order used for prev/next in the single-photo view, frozen when it opens so decisions don't reshuffle it.
    var navigation: [String] = []

    var analyzedCount = 0
    var isAnalyzing = false
    var showExport = false

    // Settings
    var autoApproveConfidence = 0.85
    var minimumTilt = 0.2
    var advanceAfterDecision = true

    private var undoStack: [[String]] = []
    private var redoStack: [[String]] = []
    private var analysisTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    static let stateFileName = ".horizonleveler.json"

    // MARK: Status

    func status(of p: Photo) -> Status {
        switch p.decision {
        case .level: return .level
        case .keep: return .keep
        case .undecided:
            guard p.analyzed else { return .pending }
            guard let d = p.detection else { return .noTilt }
            return abs(d.angle) < minimumTilt ? .alreadyLevel : .needsReview
        }
    }

    func photos(in status: Status) -> [Photo] { photos.filter { self.status(of: $0) == status } }
    func count(_ status: Status) -> Int { photos.reduce(0) { $0 + (self.status(of: $1) == status ? 1 : 0) } }
    var visible: [Photo] { photos(in: filter) }
    var toExport: [Photo] { photos.filter { $0.decision == .level && abs($0.correction) >= 0.01 } }
    func photo(_ id: String?) -> Photo? { id.flatMap { byID[$0] } }

    // MARK: Opening

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of photos. Subfolders are included."
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        analysisTask?.cancel()
        saveNow()
        folder = url
        UserDefaults.standard.set(url.path, forKey: "lastFolder")
        selection = []
        openedID = nil
        undoStack = []
        redoStack = []
        let saved = loadState(url)
        let base = url.standardizedFileURL.path + "/"
        photos = ImageLoader.listImages(in: url).map { file in
            let id = file.standardizedFileURL.path.replacingOccurrences(of: base, with: "")
            let p = Photo(id: id, url: file)
            if let s = saved[id] { p.restore(s) }
            return p
        }
        byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        analyzedCount = photos.filter(\.analyzed).count
        filter = .needsReview
        analyze()
    }

    /// Reopens the folder from last time (or one passed as `-openFolder <path>`).
    func restoreLastFolder() {
        guard folder == nil, let path = UserDefaults.standard.string(forKey: "openFolder") ?? UserDefaults.standard.string(forKey: "lastFolder"),
              FileManager.default.fileExists(atPath: path) else { return }
        open(URL(fileURLWithPath: path))
        if let id = UserDefaults.standard.string(forKey: "openPhoto"), byID[id] != nil {
            filter = status(of: byID[id]!)
            openPhoto(id)
        }
    }

    // MARK: Analysis

    private func analyze() {
        let pending = photos.filter { !$0.analyzed }.map { ($0.id, $0.url) }
        guard !pending.isEmpty else { isAnalyzing = false; return }
        isAnalyzing = true
        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        analysisTask = Task { [weak self] in
            await withTaskGroup(of: (String, Detection?).self) { group in
                var next = 0
                func add() {
                    let (id, url) = pending[next]
                    next += 1
                    group.addTask(priority: .utility) { (id, HorizonDetector.detect(url: url)) }
                }
                for _ in 0..<min(workers, pending.count) { add() }
                for await (id, detection) in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    self?.finishAnalysis(id: id, detection: detection)
                    if next < pending.count { add() }
                }
            }
            self?.isAnalyzing = false
            self?.saveSoon()
        }
    }

    private func finishAnalysis(id: String, detection: Detection?) {
        guard let p = byID[id] else { return }
        p.detection = detection
        p.analyzed = true
        analyzedCount += 1
        if let d = detection, p.decision == .undecided, p.history.count == 1,
           abs(d.angle) >= minimumTilt, d.confidence >= autoApproveConfidence {
            p.record(.level, correction: d.correction, label: "Auto " + Geometry.format(d.correction))
        }
        if analyzedCount % 50 == 0 { saveSoon() }
    }

    /// Levels every photo in "Needs review" whose confidence now meets the threshold.
    func applyAutoApprove() {
        let ids = photos(in: .needsReview).filter { ($0.detection?.confidence ?? 0) >= autoApproveConfidence }.map(\.id)
        decide(ids, .level)
    }

    // MARK: Editing (every change is undoable)

    func decide(_ ids: [String], _ decision: Decision) {
        let changed = ids.compactMap { byID[$0] }.filter { $0.decision != decision }
        guard !changed.isEmpty else { return }
        for p in changed {
            var c = p.correction
            if decision == .level, c == 0, let d = p.detection { c = d.correction }
            p.record(decision, correction: c, label: decision.label + (decision == .level ? " " + Geometry.format(c) : ""))
        }
        commit(changed.map(\.id))
    }

    func setCorrection(_ id: String, _ degrees: Double, label: String? = nil) {
        guard let p = byID[id] else { return }
        let value = (min(max(degrees, -45), 45) * 100).rounded() / 100
        p.record(.level, correction: value, label: label ?? "Correction " + Geometry.format(value))
        commit([id])
    }

    func nudge(_ id: String, by delta: Double) {
        guard let p = byID[id] else { return }
        setCorrection(id, p.correction + delta)
    }

    func resetToDetected(_ id: String) {
        guard let d = byID[id]?.detection else { return }
        setCorrection(id, d.correction, label: "Detected " + Geometry.format(d.correction))
    }

    func resetToOriginal(_ ids: [String]) {
        let changed = ids.compactMap { byID[$0] }.filter { $0.decision != .undecided || $0.correction != 0 }
        guard !changed.isEmpty else { return }
        for p in changed { p.record(.undecided, correction: 0, label: "Reset to original") }
        commit(changed.map(\.id))
    }

    func jump(_ id: String, to index: Int) {
        byID[id]?.jump(to: index)
        saveSoon()
    }

    private func commit(_ ids: [String]) {
        undoStack.append(ids)
        redoStack.removeAll()
        saveSoon()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let ids = undoStack.popLast() else { return }
        ids.forEach { byID[$0]?.undo() }
        redoStack.append(ids)
        saveSoon()
    }

    func redo() {
        guard let ids = redoStack.popLast() else { return }
        ids.forEach { byID[$0]?.redo() }
        undoStack.append(ids)
        saveSoon()
    }

    // MARK: Navigation

    func openPhoto(_ id: String) {
        navigation = visible.map(\.id)
        if !navigation.contains(id) { navigation = photos.map(\.id) }
        openedID = id
        selection = [id]
    }

    func closePhoto() {
        if let id = openedID { selection = [id] }
        openedID = nil
    }

    func step(_ delta: Int) {
        guard let id = openedID, let i = navigation.firstIndex(of: id) else { return }
        let j = i + delta
        guard navigation.indices.contains(j) else { return }
        openedID = navigation[j]
        selection = [navigation[j]]
    }

    // MARK: Persistence (a hidden JSON file in the photo folder; originals are never modified)

    private func loadState(_ folder: URL) -> [String: Photo.Saved] {
        let url = folder.appendingPathComponent(Self.stateFileName)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Photo.Saved].self, from: data)) ?? [:]
    }

    func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let folder else { return }
        let state = Dictionary(uniqueKeysWithValues: photos.filter { $0.analyzed || $0.history.count > 1 }.map { ($0.id, $0.saved) })
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: folder.appendingPathComponent(Self.stateFileName), options: .atomic)
    }
}
