#if os(macOS)
import AppKit
#endif
import Foundation
import Observation
import os

@MainActor
@Observable
final class Library {
    var folder: URL?
    var photos: [Photo] = []
    private var byID: [String: Photo] = [:]

    var filter: Filter = .review
    var selection: Set<String> = []
    /// Photo shown in the single-photo view; nil shows the grid.
    var openedID: String?
    /// Order used for prev/next in the single-photo view, frozen when it opens so decisions don't reshuffle it.
    var navigation: [String] = []

    var analyzedCount = 0
    var isAnalyzing = false
    var showExport = false
    /// Space on a photo: show it full-window (Quick Look style). Space or Esc closes.
    var quickLook = false
    /// The grid is on screen and how many columns it has, so quick look's arrows move like the grid does.
    var gridActive = false
    var gridColumns = 1
    /// The settings side panel (Mac) / bottom panel (iPhone).
    var showSettings = false
    /// Mac: the "Customize Controls" sheet for the preview's control bar.
    var showControls = false
    /// Mac View menu ▸ Zoom In / Zoom Out / Fit: the preview of this window follows (the id makes repeats count).
    struct ZoomRequest: Equatable { var command: ZoomCommand = .fit; var id = 0 }
    var zoomRequest = ZoomRequest()
    func requestZoom(_ c: ZoomCommand) { zoomRequest = ZoomRequest(command: c, id: zoomRequest.id + 1) }

    // Settings
    /// Off by default: Vision reports ~100% confidence even when it's wrong, so detections are only suggestions.
    var autoLevel = UserDefaults.standard.bool(forKey: "autoLevel") {
        didSet { UserDefaults.standard.set(autoLevel, forKey: "autoLevel") }
    }
    var autoApproveConfidence = 0.85
    /// Shot order by default: sorting by tilt scattered bursts and looked mixed up.
    var reviewOrder = ReviewOrder(rawValue: UserDefaults.standard.string(forKey: "reviewOrder") ?? "") ?? .shot {
        didSet { UserDefaults.standard.set(reviewOrder.rawValue, forKey: "reviewOrder") }
    }
    /// Open the folder from last time when the app starts.
    var reopenLastFolder = UserDefaults.standard.object(forKey: "reopenLastFolder") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reopenLastFolder, forKey: "reopenLastFolder") }
    }
    /// A short message at the bottom of the window ("Copied", "Saved 3 photos").
    var toast: String?
    /// Set when the open folder's card was ejected, to say so instead of silently showing nothing.
    var notice: String?
    #if os(macOS)
    /// What to do when a memory card is inserted.
    var cardAction = CardAction(rawValue: UserDefaults.standard.string(forKey: "cardAction") ?? "") ?? .ask {
        didSet { UserDefaults.standard.set(cardAction.rawValue, forKey: "cardAction") }
    }
    /// A card waiting in the small "Open?" banner.
    var cardOffer: CardOffer?
    #endif
    /// Show DSCF0015.JPG + DSCF0015.RAF as one photo (the JPEG). Changing it reopens the folder.
    var pairRaw = UserDefaults.standard.object(forKey: "pairRaw") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(pairRaw, forKey: "pairRaw")
            if let folder, oldValue != pairRaw { open(folder) }
        }
    }
    var minimumTilt = 0.2
    var advanceAfterDecision = UserDefaults.standard.object(forKey: "advanceAfterDecision") as? Bool ?? false {
        didSet { UserDefaults.standard.set(advanceAfterDecision, forKey: "advanceAfterDecision") }
    }

    /// One ⌘Z step: edits to some photos, or a move to the Trash.
    private enum UndoStep {
        /// The photos, and the journal summary for "Undo: …".
        case edit([String], String)
        case delete(Deletion)
        /// Redo of an undone deletion: these photos go to the Trash again.
        case redelete([String])
        var isDelete: Bool { if case .delete = self { return true } else { return false } }
    }
    private var undoStack: [UndoStep] = []
    private var redoStack: [UndoStep] = []
    /// iPhone: photos waiting for the "Move to the Trash?" dialog (the Mac uses an NSAlert).
    var pendingDelete: [String]?
    /// The toast that gets an Undo button (iPhone) after a deletion.
    var undoableToast: String?
    private var analysisTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    /// The folder's activity history (`Shared/Journal.swift`), written on every action; nil without a folder.
    @ObservationIgnored private(set) var journal: Journal?
    /// History panel: entries read so far, newest first (read lazily, a page at a time).
    var activity: [JournalEntry] = []
    var activityHasMore = false
    var activityLoading = false
    /// The panel has been opened for this folder: new entries go straight into `activity`.
    @ObservationIgnored fileprivate var activityOpen = false
    @ObservationIgnored fileprivate var activityCursors: Journal.Cursors = [:]
    /// Mac: View ▸ History (⌘Y). iPhone: ⋯ ▸ History.
    var showActivity = false

    static let stateFileName = ".horizonleveler.json"

    // MARK: Status

    func status(of p: Photo) -> Status {
        switch p.decision {
        case .level: return .level
        case .keep: return .keep
        case .undecided:
            guard p.analyzed else { return .pending }
            guard let d = p.detection else { return .noTilt }
            return hasSuggestion(p) ? .needsReview : abs(d.angle) < minimumTilt ? .alreadyLevel : .noTilt
        }
    }

    func photos(in status: Status) -> [Photo] { photos.filter { self.status(of: $0) == status } }

    func photos(for f: Filter) -> [Photo] {
        switch f {
        case .review:
            // Suggested: a tilt was found and nothing is decided yet.
            let undecided = photos.filter(hasSuggestion)
            guard reviewOrder == .tilt else { return undecided }
            // Biggest tilts first.
            return undecided.enumerated().sorted { a, b in
                let ra = reviewGroup(a.element), rb = reviewGroup(b.element)
                if ra != rb { return ra < rb }
                if ra < 2 {
                    let ta = abs(a.element.detection?.angle ?? 0), tb = abs(b.element.detection?.angle ?? 0)
                    if ta != tb { return ta > tb }
                }
                return a.offset < b.offset
            }.map(\.element)
        case .leveled: return photos.filter { $0.decision == .level || $0.bandFix != nil }
        case .kept: return photos.filter { $0.decision == .keep }
        case .favorites: return photos.filter(\.favorite)
        case .all: return photos
        case .crops: return photos.filter { $0.cropVersions.count >= 2 }
        }
    }

    /// Counting doesn't need the review ordering.
    func count(_ f: Filter) -> Int {
        switch f {
        case .review: return photos.reduce(0) { $0 + (hasSuggestion($1) ? 1 : 0) }
        default: return photos(for: f).count
        }
    }

    /// One line about a photo: its decision, or what the detector suggests.
    func note(for p: Photo) -> String {
        switch p.decision {
        case .level:
            let ratio = p.crop.map { Self.cropName($0, aspect: p.analysisAspect) }
            let rotated = abs(p.correction) >= 0.01 || p.crop == nil
            switch (rotated, ratio) {
            case (true, nil): return "Leveled " + Geometry.format(p.correction)
            case (true, let r?): return "Leveled " + Geometry.format(p.correction) + " · cropped" + (r.isEmpty ? "" : " " + r)
            case (false, let r): return "Cropped" + ((r ?? "").isEmpty ? "" : " " + r!)
            }
        case .keep: return "Kept as shot"
        case .undecided:
            guard p.analyzed else { return "Looking…" }
            // Only confident tilts are mentioned; everything else is just a photo.
            guard hasSuggestion(p), let d = p.detection else { return "As shot" }
            return "Tilted " + Geometry.format(d.angle)
        }
    }

    /// 0 = confident tilt, 2 = no suggestion. Based on the detection only, so a photo doesn't jump when you decide it.
    func reviewGroup(_ p: Photo) -> Int {
        guard let d = p.detection, d.isConfident, abs(d.angle) >= minimumTilt else { return 2 }
        return 0
    }

    /// Headings for "Biggest tilts first"; one untitled section otherwise.
    func sections(_ items: [Photo], filter: Filter) -> [PhotoSection] {
        // No headings: their counts ("Looks tilted · 227") read like a second, different total next to the tab's
        // count, and they shifted the list down in one tab only. Each row already says "Looks" or "Maybe tilted".
        [PhotoSection(id: "all", title: nil, photos: items)]
    }

    enum TagKind { case likely, leveled, kept }

    /// The small tag on a grid tile, or nil for a clean tile ("No horizon found", "Looks level").
    func tag(for p: Photo) -> (text: String, kind: TagKind)? {
        switch p.decision {
        case .level:
            if abs(p.correction) < 0.01, p.crop != nil { return ("✓ Crop", .leveled) }
            return ("✓ " + Geometry.format(p.correction) + (p.crop != nil ? " · crop" : ""), .leveled)
        case .keep: return ("Kept", .kept)
        case .undecided:
            guard hasSuggestion(p), let d = p.detection else { return nil }
            return (Geometry.format(d.angle), .likely)
        }
    }

    /// True when the detectors are sure this undecided photo is tilted (`Detection.isConfident`). Only then does
    /// the app say anything about leveling.
    func hasSuggestion(_ p: Photo) -> Bool {
        guard p.decision == .undecided, let d = p.detection, d.isConfident else { return false }
        return abs(d.angle) >= minimumTilt
    }
    func count(_ status: Status) -> Int { photos.reduce(0) { $0 + (self.status(of: $1) == status ? 1 : 0) } }
    var visible: [Photo] { photos(for: filter) }
    var toExport: [Photo] { photos.filter(\.hasEdits) }
    func photo(_ id: String?) -> Photo? { id.flatMap { byID[$0] } }

    // MARK: Opening

    #if os(macOS)
    /// Opens in this tab if it's empty, else in new tabs (several folders can be picked at once).
    func chooseFolder() { WindowRouter.shared.chooseFolders(from: self) }
    #endif

    private var scopedFolder: URL?

    func open(_ url: URL) {
        analysisTask?.cancel()
        saveNow()
        // Folders picked in Files (iOS) are security-scoped: hold access while the folder is open.
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = url.startAccessingSecurityScopedResource() ? url : nil
        folder = url
        UserDefaults.standard.set(url.path, forKey: "lastFolder")
        // Keep the bookmark in step with the path; drop it if it can't be made, so it never points elsewhere.
        if let bookmark = try? url.bookmarkData() {
            UserDefaults.standard.set(bookmark, forKey: "lastFolderBookmark")
        } else {
            UserDefaults.standard.removeObject(forKey: "lastFolderBookmark")
        }
        selection = []
        openedID = nil
        undoStack = []
        redoStack = []
        resetActivity(Journal(folder: url))
        let saved = loadState(url)
        let base = url.standardizedFileURL.path + "/"
        let files = ImageLoader.listImages(in: url)
        Self.log("open: \(url.path) -> \(files.count) files, readable=\(FileManager.default.isReadableFile(atPath: url.path))")
        let groups = pairRaw ? ImageLoader.pairRawWithJPEG(files) : files.map { ImageLoader.Group(primary: $0, companions: []) }
        photos = groups.map { group in
            let file = group.primary
            let id = file.standardizedFileURL.path.replacingOccurrences(of: base, with: "")
            let p = Photo(id: id, url: file, companions: group.companions)
            if let s = saved[id] { p.restore(s) }
            return p
        }
        byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        // Results from an older detector are re-checked in the background; decisions are kept.
        for p in photos where p.analyzed && p.analysisVersion < HorizonDetector.version { p.analyzed = false }
        analyzedCount = photos.filter(\.analyzed).count
        notice = nil
        filter = .review
        if !autoLevel { clearAutomaticDecisions() }
        #if os(macOS)
        importFinderFavorites()
        #endif
        analyze()
    }

    /// The folder from last time: its bookmark if that still resolves, else the saved path.
    private func resolvedLastFolder() -> URL? {
        #if os(macOS)
        // On the Mac the saved path is authoritative; the bookmark is only a fallback (it can lag behind).
        if let path = UserDefaults.standard.string(forKey: "lastFolder"), FileManager.default.fileExists(atPath: path) {
            Self.log("restore: path \(path)")
            return URL(fileURLWithPath: path)
        }
        #endif
        if let data = UserDefaults.standard.data(forKey: "lastFolderBookmark") {
            var stale = false
            do {
                let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
                Self.log("restore: bookmark -> \(url.path) stale=\(stale)")
                return url
            } catch {
                Self.log("restore: bookmark failed: \(error.localizedDescription)")
            }
        }
        guard let path = UserDefaults.standard.string(forKey: "lastFolder") else {
            Self.log("restore: no saved folder")
            return nil
        }
        let exists = FileManager.default.fileExists(atPath: path)
        Self.log("restore: path \(path) exists=\(exists)")
        return exists ? URL(fileURLWithPath: path) : nil
    }

    nonisolated static func log(_ message: String) {
        os_log("%{public}@", log: OSLog(subsystem: "app.horizonleveler", category: "library"), type: .info, message)
    }

    /// Reopens the folder from last time (or one passed as `-openFolder <path>`).
    func restoreLastFolder() {
        guard folder == nil else { return }
        if let path = UserDefaults.standard.string(forKey: "openFolder"), FileManager.default.fileExists(atPath: path) {
            open(URL(fileURLWithPath: path))
        } else if reopenLastFolder, let url = resolvedLastFolder() {
            open(url)
        } else {
            return
        }
        if let id = UserDefaults.standard.string(forKey: "openPhoto"), byID[id] != nil {
            filter = .all
            openPhoto(id)
        }
    }

    // MARK: Analysis

    private func analyze() {
        let pending = photos.filter { !$0.analyzed }.map { ($0.id, $0.url, $0.rawCompanion, $0.info == nil ? $0.companions : nil) }
        guard !pending.isEmpty else { isAnalyzing = false; return }
        isAnalyzing = true
        let started = Date()
        Self.log("analysis: \(pending.count) photos to check")
        // Memory cards read best with few parallel requests; local drives can take more.
        let removable = (try? folder?.resourceValues(forKeys: [.volumeIsRemovableKey]).volumeIsRemovable) ?? false
        let workers = removable == true ? 3 : max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        analysisTask = Task { [weak self] in
            await withTaskGroup(of: (String, Detection?, PhotoInfo?).self) { group in
                var next = 0
                func add() {
                    let (id, url, raw, needsInfo) = pending[next]
                    next += 1
                    group.addTask(priority: .utility) {
                        await ReadGate.shared.enter(onScreen: false)
                        let image = HorizonDetector.analysisImage(url: url, rawCompanion: raw)
                        // Camera details too when this read just opened the file itself (no RAW twin): its header
                        // is already in memory, so it costs nothing extra. Pairs get theirs when shown.
                        let info = raw == nil ? needsInfo.flatMap { PhotoInfo.read(url: url, companions: $0) } : nil
                        await ReadGate.shared.leave()
                        guard let image else { return (id, nil, info) }
                        ImageCache.shared.prime(url: url, from: image)   // the grid thumbnail, for free
                        return (id, HorizonDetector.analyze(image), info)
                    }
                }
                for _ in 0..<min(workers, pending.count) { add() }
                for await (id, detection, info) in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let info, let p = self?.byID[id], p.info == nil { p.info = info }
                    self?.finishAnalysis(id: id, detection: detection)
                    if next < pending.count { add() }
                }
            }
            Self.log(String(format: "analysis: done in %.1fs (%.0f ms/photo)", Date().timeIntervalSince(started),
                            Date().timeIntervalSince(started) * 1000 / Double(max(pending.count, 1))))
            self?.isAnalyzing = false
            self?.saveSoon()
        }
    }

    private func finishAnalysis(id: String, detection: Detection?) {
        guard let p = byID[id] else { return }
        p.detection = detection
        p.analyzed = true
        p.analysisVersion = HorizonDetector.version
        analyzedCount += 1
        if autoLevel, let d = detection, d.isConfident, p.decision == .undecided, p.history.count == 1,
           abs(d.angle) >= minimumTilt, d.confidence >= autoApproveConfidence {
            let before = journalStates([id])
            p.record(.level, correction: d.correction, label: "Auto " + Geometry.format(d.correction))
            logActivity(.autoLevel, [id], before: before)
        }
        if analyzedCount % 50 == 0 { saveSoon() }
    }

    /// Levels every undecided photo that has a suggestion. One ⌘Z undoes it.
    func applyAllSuggestions() {
        decide(photos(for: .review).filter(hasSuggestion).map(\.id), .level)
    }

    /// The folder's card was ejected: stop work and show the start page with a note.
    func closeFolder(notice: String? = nil) {
        analysisTask?.cancel()
        saveNow()
        folder = nil
        photos = []
        byID = [:]
        openedID = nil
        quickLook = false
        selection = []
        navigation = []
        isAnalyzing = false
        resetActivity(nil)
        self.notice = notice
    }

    /// Kept for older call sites.
    func applyAutoApprove() { applyAllSuggestions() }

    /// Earlier versions leveled confident detections automatically. Send those untouched photos back to review,
    /// keeping the angle as the suggestion (L applies it again). Recorded in history; one ⌘Z restores them.
    func clearAutomaticDecisions() {
        let auto = photos.filter { p in
            p.decision == .level && p.index == p.history.count - 1 && p.history.count == 2 && p.history[1].label.hasPrefix("Auto")
        }
        guard !auto.isEmpty else { return }
        let before = journalStates(auto.map(\.id))
        for p in auto { p.record(.undecided, correction: p.correction, label: "Automatic level undone") }
        commit(auto.map(\.id), .undecided, before: before, summary: "Sent \(auto.count) automatic level\(auto.count == 1 ? "" : "s") back to review")
    }

    // MARK: Saving into the original files

    static let backupFolderName = ".horizonleveler-originals"

    /// Where the untouched file is kept once a photo has been saved into its original.
    func backupURL(for p: Photo) -> URL? {
        folder?.appendingPathComponent(Self.backupFolderName, isDirectory: true).appendingPathComponent(p.id)
    }

    func hasBackup(_ p: Photo) -> Bool {
        backupURL(for: p).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Photos that "Save to original" would change: leveled, and a format we can write (not RAW).
    func savable(_ ids: [String]) -> [Photo] {
        ids.compactMap { byID[$0] }.filter { $0.hasEdits && !ImageLoader.isRaw($0.url) }
    }

    /// Writes the leveled photo over the original JPEG/HEIC/TIFF. The first time, the untouched file is moved
    /// to a hidden backup folder; every save renders from that untouched file, so quality never degrades.
    func saveToOriginals(_ ids: [String], progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) async -> (saved: Int, failed: [String]) {
        let items = savable(ids)
        var saved = 0, failed: [String] = [], savedIDs: [String] = []
        let before = journalStates(items.map(\.id))
        for (i, p) in items.enumerated() {
            progress(i, items.count)
            guard let backup = backupURL(for: p) else { continue }
            // Render from the untouched backup with the total rotation, unless an earlier save already cropped
            // the file: then the current file is the base (a crop can't be re-derived from the backup).
            let fromBackup = !p.savedHadCrop
            let total = fromBackup ? p.savedCorrection + p.appliedCorrection : p.appliedCorrection
            let crop = p.appliedCrop
            // From the untouched backup the earlier saved band fix has to be applied again (unless a new one replaces
            // it); from the current file only a new fix is applied (an earlier one is already in it).
            let band = fromBackup ? (p.bandFix ?? p.savedBandFix) : p.bandFix
            let source = p.url
            let format: ExportFormat = { switch source.pathExtension.lowercased() {
                case "heic", "heif": return .heic
                case "tif", "tiff": return .tiff
                default: return .jpeg } }()
            let result: String? = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                do {
                    if !fm.fileExists(atPath: backup.path) {
                        try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.copyItem(at: source, to: backup)
                    }
                    let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + source.pathExtension)
                    try Renderer.export(source: fromBackup ? backup : source, degrees: total, crop: crop, bandFix: band,
                                        to: temp, format: format, quality: 0.96)
                    _ = try fm.replaceItemAt(source, withItemAt: temp)
                    return nil
                } catch { return error.localizedDescription }
            }.value
            if let result { failed.append("\(p.name): \(result)"); continue }
            p.savedCorrection = fromBackup ? total : p.savedCorrection + total
            p.savedHadCrop = p.savedHadCrop || crop != nil
            if fromBackup { p.savedBandFix = band } else if band != nil { p.savedBandFix = band }
            p.startFresh(label: "Saved to original " + Geometry.format(total) + (crop != nil ? " · cropped" : "")
                         + (band != nil ? " · bands fixed" : ""))
            ImageCache.shared.evict(p.url)
            BandFixStore.shared.evict(p.url)
            analyzedCount -= 1
            saved += 1
            savedIDs.append(p.id)
        }
        progress(items.count, items.count)
        logActivity(.saveToOriginal, savedIDs, before: before,
                    extra: JournalExtra(backups: savedIDs.compactMap { byID[$0].flatMap(backupURL(for:))?.path }), keepUnchanged: true)
        dropEditUndo()    // the files changed; old undo steps no longer apply (deletions still can be undone)
        saveNow()
        analyze()
        return (saved, failed)
    }

    /// Save to original with the usual toast ("Level a photo first…" when there's nothing to save).
    func saveToOriginalsWithToast(_ ids: [String]) async {
        guard !savable(ids).isEmpty else { toast = "Level a photo first, then save it to the original"; return }
        let r = await saveToOriginals(ids)
        toast = r.failed.isEmpty ? (r.saved == 1 ? "Saved to original (backup kept)" : "Saved \(r.saved) originals (backups kept)")
                                 : "Saved \(r.saved), \(r.failed.count) failed"
    }

    /// Puts the untouched file back from the backup folder.
    func restoreOriginals(_ ids: [String], reverting entry: JournalEntry? = nil) {
        var restored = 0, restoredIDs: [String] = []
        let before = journalStates(ids)
        for p in ids.compactMap({ byID[$0] }) {
            guard let backup = backupURL(for: p), FileManager.default.fileExists(atPath: backup.path) else { continue }
            do {
                _ = try FileManager.default.replaceItemAt(p.url, withItemAt: backup)
                p.savedCorrection = 0
                p.savedBandFix = nil
                p.startFresh(label: "Original restored")
                ImageCache.shared.evict(p.url)
                BandFixStore.shared.evict(p.url)
                analyzedCount -= 1
                restored += 1
                restoredIDs.append(p.id)
            } catch {
                toast = "Couldn't restore \(p.name): \(error.localizedDescription)"
            }
        }
        if let entry {
            if restored == 0 { toast = "No backup left to restore" }
            logActivity(.revert, restoredIDs, before: [:], summary: "Reverted: " + entry.summary,
                        extra: JournalExtra(revertOf: entry.id), keepUnchanged: true)
        } else {
            logActivity(.restoreOriginal, restoredIDs, before: before, keepUnchanged: true)
        }
        if restored > 0 {
            dropEditUndo()
            toast = restored == 1 ? "Original restored" : "\(restored) originals restored"
            saveNow()
            analyze()
        }
    }

    /// The photos ⌘C / Copy act on: the open photo in the preview, else the grid selection.
    func copyTargets(preferOpened: Bool) -> [Photo] {
        if preferOpened, let p = photo(openedID) { return targets(for: p.id).compactMap { byID[$0] } }
        let picked = navigation.filter { selection.contains($0) }.compactMap { byID[$0] }
        if !picked.isEmpty { return picked }
        return photo(openedID).map { [$0] } ?? []
    }

    // MARK: Editing (every change is undoable)

    func decide(_ ids: [String], _ decision: Decision) {
        let changed = ids.compactMap { byID[$0] }.filter { $0.decision != decision }
        guard !changed.isEmpty else { return }
        let before = journalStates(changed.map(\.id))
        for p in changed {
            var c = p.correction
            if decision == .level, c == 0, let d = p.detection { c = d.correction }
            p.record(decision, correction: c, label: decision.label + (decision == .level ? " " + Geometry.format(c) : ""))
        }
        commit(changed.map(\.id), decision == .level ? .level : decision == .keep ? .keep : .undecided, before: before)
    }

    /// Whether a photo belongs in a list (tab).
    func belongs(_ p: Photo, to f: Filter) -> Bool {
        switch f {
        case .all: return true
        case .review: return hasSuggestion(p)
        case .leveled: return p.decision == .level || p.bandFix != nil
        case .kept: return p.decision == .keep
        case .favorites: return p.favorite
        case .crops: return p.cropVersions.count >= 2
        }
    }

    /// Decides photos and keeps the current list honest: photos that no longer belong (e.g. Kept while viewing
    /// Leveled) leave it at once and the next photo takes their place; otherwise the open photo advances.
    func decideAndMove(_ ids: [String], _ d: Decision) {
        decide(ids, d)
        // Default: stay on the photo and show the result; nothing jumps or disappears until you move on.
        // The list is refreshed when you change tabs. "Next photo after a decision" brings back the old flow.
        guard advanceAfterDecision else { return }
        let leaving = ids.filter { id in byID[id].map { !belongs($0, to: filter) } ?? false }
        if !leaving.isEmpty {
            removeFromList(leaving)
        } else if ids.count == 1, ids.first == openedID, advanceAfterDecision, d != .undecided {
            step(1)
        }
    }

    // MARK: Quiet leveling (corner chip + level tool)

    /// The level tool is open in the preview (Mac) / editor (iPhone): headline, As shot | Leveled switch, ruler,
    /// guide line and the two-point picker. Closed, the preview is just the photo. R (Mac) or the level button.
    var levelTool = false {
        didSet { if levelTool { fixesTool = false } }
    }
    /// Photos just leveled from the corner chip (or L), for ~4 s, so the chip can offer "Leveled · Undo" even after
    /// the view moved on to the next photo.
    var justLeveled: [String] = []
    private var justLeveledToken = 0

    /// Level, and when the open photo is among them, open the level tool right away so the angle can be
    /// fine-tuned (ruler, two points, [ ]). L, right-click ▸ Level, Photo ▸ Level and the corner chip.
    func levelAndAdjust(_ ids: [String]) {
        quickLevel(ids)
        if let opened = openedID, ids.contains(opened) { levelTool = true }
    }

    /// Level (decide-and-move, like L) and offer Undo for a few seconds.
    func quickLevel(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let changing = ids.filter { byID[$0]?.decision != .level }
        decideAndMove(ids, .level)
        guard !changing.isEmpty else { return }
        // Moved on to the next photo: the chip there belongs to that photo, so the undo goes in a toast instead.
        if let opened = openedID, !changing.contains(opened) {
            let name = changing.count == 1 ? (byID[changing[0]]?.name ?? "photo") : "\(changing.count) photos"
            #if os(macOS)
            toast = "Leveled \(name) · ⌘Z to undo"
            #else
            toast = "Leveled \(name)"
            undoableToast = toast
            #endif
        }
        justLeveled = changing
        justLeveledToken += 1
        let token = justLeveledToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.justLeveledToken == token else { return }
            self.justLeveled = []
        }
    }

    /// "Undo" on the chip: those photos go back to undecided and the (first) one is shown again.
    func undoQuickLevel() {
        let ids = justLeveled.filter { byID[$0] != nil }
        justLeveled = []
        justLeveledToken += 1
        guard let first = ids.first else { return }
        decide(ids, .undecided)
        if openedID != nil { openPhoto(first) } else { selection = Set(ids) }
    }

    /// Takes photos out of the visible list, selecting the one that took the first one's place.
    func removeFromList(_ ids: [String]) {
        let set = Set(ids)
        guard let first = navigation.indices.first(where: { set.contains(navigation[$0]) }) else { return }
        let openedLeaves = openedID.map(set.contains) ?? false
        navigation.removeAll { set.contains($0) }
        selection.subtract(set)
        guard !navigation.isEmpty else {
            if openedLeaves { openedID = nil }
            return
        }
        let next = navigation[min(first, navigation.count - 1)]
        if openedLeaves || openedID == nil { openedID = next }
        if selection.isEmpty { selection = [next] }
    }

    /// ♥ the photos, or, when all of them already are, un-♥ them. On the Mac the files (RAW twin included)
    /// get Finder's Red tag too. Un-♥ while viewing Favorites takes them out of the list.
    func toggleFavorite(_ ids: [String]) {
        let items = ids.compactMap { byID[$0] }
        guard !items.isEmpty else { return }
        let value = items.contains { !$0.favorite }
        let before = journalStates(items.map(\.id))
        for p in items { p.favorite = value }
        logActivity(value ? .favorite : .unfavorite, items.map(\.id), before: before)
        #if os(macOS)
        FinderTag.set(value, on: items.flatMap { [$0.url] + $0.companions })
        #endif
        saveSoon()
        if !value, filter == .favorites { removeFromList(items.map(\.id)) }
        mirrorFavoriteInPhotos(items.map(\.url), value)
    }

    static let photosFavoriteSyncKey = "photosFavoriteSync"

    /// ♥ here = ♥ in Apple Photos for copies already imported there (Settings ▸ "Mirror favorites in Apple Photos",
    /// on by default). The first time, Photos asks for access; if it's refused, a toast says where to change it.
    private func mirrorFavoriteInPhotos(_ urls: [URL], _ value: Bool) {
        guard UserDefaults.standard.object(forKey: Self.photosFavoriteSyncKey) as? Bool ?? true else { return }
        Task { [weak self] in
            do { try await PhotosSync.setFavorite(urls, to: value) }
            catch {
                guard let self else { return }
                if !UserDefaults.standard.bool(forKey: "photosFavoriteSyncWarned") {
                    UserDefaults.standard.set(true, forKey: "photosFavoriteSyncWarned")
                    self.toast = "Couldn't update Apple Photos: allow access in System Settings ▸ Privacy ▸ Photos"
                }
            }
        }
    }

    // MARK: Apple Photos (only on the owner's action)

    /// Imports the original files into Apple Photos (RAW twin as the alternate), favorites as favorites.
    func addToPhotos(_ ids: [String]) {
        let items = ids.compactMap { byID[$0] }.map { PhotosSync.Item(url: $0.url, raw: $0.rawCompanion, favorite: $0.favorite) }
        guard !items.isEmpty else { return }
        let favorites = items.filter(\.favorite).count
        let found = ids.filter { byID[$0] != nil }
        toast = "Adding \(items.count) to Photos…"
        Task {
            do {
                let n = try await PhotosSync.add(items)
                logActivity(.addToPhotos, found, before: [:], summary: found.count == 1 ? nil : "Added \(n) photos to Photos", keepUnchanged: true)
                toast = "Added \(n) to Photos" + (favorites > 0 ? " (\(favorites) favorite\(favorites == 1 ? "" : "s"))" : "")
            } catch {
                Self.log("photos add: \(error.localizedDescription)")
                toast = "Couldn't add to Photos: \(error.localizedDescription)"
            }
        }
    }

    /// Marks copies already in Apple Photos as favorites (never unmarks).
    func syncFavoritesToPhotos() {
        let urls = photos.filter(\.favorite).map(\.url)
        let favoriteIDs = photos.filter(\.favorite).map(\.id)
        guard !urls.isEmpty else { toast = "No favorites in this folder"; return }
        toast = "Syncing favorites to Photos…"
        Task {
            do {
                let n = try await PhotosSync.syncFavorites(urls)
                if n > 0 { logActivity(.photosFavorites, favoriteIDs, before: [:], summary: "Marked \(n) favorite\(n == 1 ? "" : "s") in Photos", keepUnchanged: true) }
                toast = n == 0 ? "None of the \(urls.count) favorites are in Photos yet" : "\(n) of \(urls.count) favorites marked in Photos"
            } catch {
                Self.log("photos sync: \(error.localizedDescription)")
                toast = "Couldn't sync: \(error.localizedDescription)"
            }
        }
    }

    #if os(macOS)
    /// Files already carrying Finder's Red tag count as favorites (read in the background, one xattr per file).
    private func importFinderFavorites() {
        let folder = self.folder
        let files = photos.filter { !$0.favorite }.map { ($0.id, [$0.url] + $0.companions) }
        guard !files.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let tagged = files.filter { $0.1.contains(where: FinderTag.has) }.map(\.0)
            guard !tagged.isEmpty else { return }
            await self?.markFavorites(tagged, in: folder)
        }
    }

    private func markFavorites(_ ids: [String], in folder: URL?) {
        guard self.folder == folder else { return }
        for id in ids { byID[id]?.favorite = true }
        Self.log("favorites: \(ids.count) imported from Finder tags")
        saveSoon()
    }
    #endif

    /// Sets (or clears, with nil) the crop. Marks the photo to be edited, like leveling does.
    func setCrop(_ id: String, _ crop: CGRect?, label: String) {
        guard let p = byID[id] else { return }
        let before = journalStates([id])
        recordCrop(p, crop, label: label)
        commit([id], .crop, before: before)
    }

    private func recordCrop(_ p: Photo, _ crop: CGRect?, label: String) {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let value = crop.flatMap { $0.standardized.width < 0.999 || $0.standardized.height < 0.999 ? $0.standardized.intersection(full) : nil }
        p.record(.level, correction: p.correction, label: label, crop: .some(value))
    }

    /// "4:5", "1:1"… for a crop with a common ratio, or "" for a free crop.
    static func cropName(_ c: CGRect, aspect: CGFloat) -> String {
        let r = aspect * c.width / max(c.height, 0.0001)
        for (name, value) in [("1:1", 1.0), ("4:5", 0.8), ("5:4", 1.25), ("3:2", 1.5), ("2:3", 2.0 / 3), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:3", 4.0 / 3), ("3:4", 0.75)]
        where abs(r - value) < 0.01 { return name }
        return ""
    }

    /// `action` for the journal; by default "Two points …" labels are two-point leveling, anything else the ruler.
    func setCorrection(_ id: String, _ degrees: Double, label: String? = nil, action: JournalAction? = nil) {
        guard let p = byID[id] else { return }
        let before = journalStates([id])
        let value = (min(max(degrees, -45), 45) * 100).rounded() / 100
        p.record(.level, correction: value, label: label ?? "Correction " + Geometry.format(value))
        commit([id], action ?? (label?.hasPrefix("Two points") == true ? .twoPoint : .ruler), before: before)
    }

    func nudge(_ id: String, by delta: Double) {
        guard let p = byID[id] else { return }
        setCorrection(id, p.correction + delta, action: .nudge)
    }

    func resetToDetected(_ id: String) {
        guard let d = byID[id]?.detection else { return }
        setCorrection(id, d.correction, label: "Detected " + Geometry.format(d.correction), action: .tilt)
    }

    func resetToOriginal(_ ids: [String]) {
        let changed = ids.compactMap { byID[$0] }.filter { $0.decision != .undecided || $0.correction != 0 }
        guard !changed.isEmpty else { return }
        let before = journalStates(changed.map(\.id))
        for p in changed { p.record(.undecided, correction: 0, label: "Reset to original") }
        commit(changed.map(\.id), .reset, before: before)
    }

    func jump(_ id: String, to index: Int) {
        let before = journalStates([id])
        byID[id]?.jump(to: index)
        if let p = byID[id] {
            logActivity(.jump, [id], before: before, summary: "\(Self.shortName(id)): back to “\(p.current.label)”")
        }
        saveSoon()
    }

    /// One undo step plus one journal entry (`before` = the photos' states before the change).
    private func commit(_ ids: [String], _ action: JournalAction, before: [String: JournalState], summary: String? = nil) {
        let text = logActivity(action, ids, before: before, summary: summary)
        undoStack.append(.edit(ids, text ?? summary ?? describe(action, ids, after: [:])))
        redoStack.removeAll()
        saveSoon()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let step = undoStack.popLast() else { return }
        switch step {
        case .edit(let ids, let label):
            let before = journalStates(ids)
            ids.forEach { byID[$0]?.undo() }
            redoStack.append(step)
            logActivity(.undo, ids, before: before, summary: "Undo: " + label)
        case .delete(let d):
            let back = restoreDeletion(d, prefix: "Undo: ")
            if !back.isEmpty { redoStack.append(.redelete(back)) }
        case .redelete: break
        }
        saveSoon()
    }

    func redo() {
        guard let step = redoStack.popLast() else { return }
        switch step {
        case .redelete(let ids):
            // Move the same photos to the Trash again (no second question).
            let keep = redoStack
            delete(ids, prefix: "Redo: ")
            redoStack = keep
        case .edit(let ids, let label):
            let before = journalStates(ids)
            ids.forEach { byID[$0]?.redo() }
            undoStack.append(step)
            logActivity(.redo, ids, before: before, summary: "Redo: " + label)
            saveSoon()
        case .delete: break
        }
    }

    /// Forget edit steps (the files changed under them) but keep deletions, which only need the Trash.
    private func dropEditUndo() {
        undoStack.removeAll { !$0.isDelete }
        redoStack = []
    }

    // MARK: Selection

    /// What an action on one photo acts on: the whole selection when that photo is part of a multi-selection.
    func targets(for id: String) -> [String] {
        guard selection.count > 1, selection.contains(id) else { return [id] }
        let ordered = navigation.filter(selection.contains)
        return ordered + selection.subtracting(ordered).filter { byID[$0] != nil }.sorted()
    }

    // MARK: Move to Trash (undoable; nothing is ever deleted permanently)

    static let confirmDeleteKey = "confirmDelete"

    func deleteTitle(_ ids: [String]) -> String {
        ids.count == 1 ? "Move “\(byID[ids[0]]?.name ?? "this photo")” to the Trash?" : "Move \(ids.count) photos to the Trash?"
    }

    func deleteMessage(_ ids: [String]) -> String {
        let raw = ids.contains { byID[$0]?.companions.isEmpty == false }
        #if os(macOS)
        let undo = "⌘Z puts " + (ids.count == 1 ? "it" : "them") + " back."
        #else
        let undo = "Undo puts " + (ids.count == 1 ? "it" : "them") + " back."
        #endif
        return (raw ? "RAW companions go too. " : "") + undo
    }

    /// Asks first (unless "Don't ask again" was chosen), then moves the photos and their RAW twins to the Trash.
    func requestDelete(_ ids: [String]) {
        let ids = ids.filter { byID[$0] != nil }
        guard !ids.isEmpty else { return }
        guard UserDefaults.standard.object(forKey: Self.confirmDeleteKey) as? Bool ?? true else { delete(ids); return }
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = deleteTitle(ids)
        alert.informativeText = deleteMessage(ids)
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(false, forKey: Library.confirmDeleteKey) }
            self?.delete(ids)
        }
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
        #else
        pendingDelete = ids
        #endif
    }

    /// Moves each photo's file and its companions (RAW twin) to the Trash (or, where the Trash isn't available,
    /// a hidden folder in the photo folder), keeping where they went so ⌘Z can bring them back. Backups stay.
    func delete(_ ids: [String], prefix: String = "") {
        let set = Set(ids)
        let wasOpened = openedID
        var items: [DeletedPhoto] = [], failed: [String] = []
        for (index, p) in photos.enumerated() where set.contains(p.id) {
            var moved: [TrashedFile] = []
            do {
                for url in [p.url] + p.companions where FileManager.default.fileExists(atPath: url.path) {
                    moved.append(TrashedFile(original: url, trashed: try Trash.move(url, folder: folder)))
                }
            } catch {
                // Put back what already moved, so a photo is never half gone.
                for f in moved.reversed() { try? Trash.restore(f) }
                Self.log("trash \(p.name): \(error.localizedDescription)")
                failed.append(p.name)
                continue
            }
            items.append(DeletedPhoto(photo: p, index: index, navIndex: navigation.firstIndex(of: p.id), files: moved))
        }
        guard !items.isEmpty else {
            if let name = failed.first { toast = "Couldn't move \(name) to the Trash" }
            return
        }
        let goneIDs = items.map(\.photo.id)
        let before = journalStates(goneIDs)
        let moved = items.flatMap { item in
            item.files.map { JournalExtra.Moved(photo: item.photo.id, from: $0.original.path, to: $0.trashed.path) }
        }
        let gone = Set(goneIDs)
        removeFromList(goneIDs)
        navigation.removeAll { gone.contains($0) }
        selection.subtract(gone)
        photos.removeAll { gone.contains($0.id) }
        for id in gone { byID[id] = nil }
        analyzedCount -= items.filter(\.photo.analyzed).count
        if wasOpened == nil { openedID = nil }
        else if let id = openedID, byID[id] == nil { openedID = navigation.first }
        undoStack.append(.delete(Deletion(items: items, openedID: wasOpened)))
        redoStack.removeAll()
        logActivity(.delete, goneIDs, before: before, summary: prefix + describe(.delete, goneIDs, after: [:]),
                    extra: JournalExtra(trashed: moved), keepUnchanged: true)
        saveNow()
        var text = items.count == 1 ? "Moved to the Trash" : "Moved \(items.count) to the Trash"
        if !failed.isEmpty { text += " · \(failed.count) couldn't be moved" }
        #if os(macOS)
        text += " · ⌘Z puts back"
        #endif
        toast = text
        undoableToast = text
    }

    /// Moves the files back from the Trash and puts the photos (decisions, crops, ♥ and all) where they were.
    private func restoreDeletion(_ d: Deletion, prefix: String = "") -> [String] {
        var back: [DeletedPhoto] = [], skipped: [String] = []
        for item in d.items.sorted(by: { $0.index < $1.index }) {
            var primaryBack = !item.files.contains { $0.original == item.photo.url }
            for f in item.files {
                do {
                    try Trash.restore(f)
                    if f.original == item.photo.url { primaryBack = true }
                } catch {
                    Self.log("put back \(f.original.lastPathComponent): \(error.localizedDescription)")
                    skipped.append(f.original.lastPathComponent)
                    // The photo itself can't come back: leave its RAW twin in the Trash too (no orphans).
                    if f.original == item.photo.url { break }
                }
            }
            guard primaryBack, byID[item.photo.id] == nil else { continue }
            photos.insert(item.photo, at: min(item.index, photos.count))
            byID[item.photo.id] = item.photo
            if item.photo.analyzed { analyzedCount += 1 }
            back.append(item)
        }
        for item in back.sorted(by: { ($0.navIndex ?? .max) < ($1.navIndex ?? .max) }) {
            guard let i = item.navIndex, !navigation.contains(item.photo.id) else { continue }
            navigation.insert(item.photo.id, at: min(i, navigation.count))
        }
        undoableToast = nil
        guard !back.isEmpty else {
            toast = "Couldn't put back " + (skipped.isEmpty ? "the photos" : skipped.joined(separator: ", "))
            return []
        }
        let ids = back.map(\.photo.id)
        selection = Set(ids)
        if let id = d.openedID, ids.contains(id) { openedID = id }
        var text = back.count == 1 ? "Put back from the Trash" : "Put back \(back.count) from the Trash"
        if !skipped.isEmpty { text += " · skipped " + skipped.joined(separator: ", ") + " (taken or gone)" }
        toast = text
        logActivity(.restoreFromTrash, ids, before: [:], summary: prefix + describe(.restoreFromTrash, ids, after: [:]), keepUnchanged: true)
        saveNow()
        return ids
    }

    // MARK: Crop versions

    static func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.002 && abs(a.minY - b.minY) < 0.002 && abs(a.width - b.width) < 0.002 && abs(a.height - b.height) < 0.002
    }

    /// "+ Version": keeps this crop as one of the photo's tries. Doesn't change the applied crop.
    func addCropVersion(_ id: String, rect: CGRect, ratio: String) {
        guard let p = byID[id] else { return }
        if let i = p.cropVersions.firstIndex(where: { Self.sameRect($0.rect, rect) }) {
            toast = "Already saved as version \(i + 1)"
            return
        }
        let before = journalStates([id])
        p.cropVersions.append(CropVersion(rect: rect.standardized, ratio: ratio))
        logActivity(.versionAdd, [id], before: before, summary: "Added crop version \(p.cropVersions.count) to \(Self.shortName(id))")
        toast = "Saved version \(p.cropVersions.count)"
        saveSoon()
    }

    func removeCropVersion(_ id: String, _ versionID: UUID) {
        guard let p = byID[id] else { return }
        let before = journalStates([id])
        let number = (p.cropVersions.firstIndex { $0.id == versionID } ?? 0) + 1
        p.cropVersions.removeAll { $0.id == versionID }
        if p.chosenVersionID == versionID { p.chosenVersionID = nil }
        logActivity(.versionRemove, [id], before: before, summary: "Removed crop version \(number) from \(Self.shortName(id))")
        saveSoon()
    }

    /// Makes a version the applied crop (recorded in history, so ⌘Z goes back).
    func chooseCropVersion(_ id: String, _ versionID: UUID) {
        guard let p = byID[id], let i = p.cropVersions.firstIndex(where: { $0.id == versionID }) else { return }
        let v = p.cropVersions[i]
        let before = journalStates([id])
        recordCrop(p, v.rect, label: "Crop version \(i + 1)" + (v.ratio.isEmpty ? "" : " · " + v.ratio))
        p.chosenVersionID = v.id
        commit([id], .versionChoose, before: before, summary: "Chose crop version \(i + 1) for \(Self.shortName(id))")
    }

    // MARK: Film scan fixes (hidden; Settings ▸ Advanced ▸ "Film scan fixes")

    /// Settings ▸ Advanced: shows the Fixes menus, panel and buttons. Off by default (a personal feature).
    static let labFixesKey = "labFixes"
    static var labFixes: Bool { UserDefaults.standard.bool(forKey: labFixesKey) }

    /// Mac: the Fixes panel is open in the preview (like the level tool). iPhone: the Fixes sheet.
    var fixesTool = false

    /// Sets (or, with nil, removes) one photo's band fix as one undoable step.
    func setBandFix(_ id: String, _ settings: BandFixSettings?) {
        guard let p = byID[id], p.bandFix != settings else { return }
        let before = journalStates([id])
        p.record(p.decision, correction: p.correction,
                 label: settings == nil ? "Band fix removed" : (p.bandFix == nil ? "Bands fixed" : "Band fix adjusted"),
                 bandFix: .some(settings))
        commit([id], .bandFix, before: before)
    }

    /// Removes the band fix from the photos that have one (one undo step).
    func removeBandFix(_ ids: [String]) {
        let items = ids.compactMap { byID[$0] }.filter { $0.bandFix != nil }
        guard !items.isEmpty else { toast = "No band fix to remove"; return }
        let before = journalStates(items.map(\.id))
        for p in items { p.record(p.decision, correction: p.correction, label: "Band fix removed", bandFix: .some(nil)) }
        commit(items.map(\.id), .bandFix, before: before,
               summary: items.count == 1 ? nil : "Removed the band fix from \(items.count) photos")
        toast = items.count == 1 ? "Band fix removed" : "Removed the band fix from \(items.count) photos"
    }

    /// Detects the bands on each photo (in the background, through the ReadGate) and stores `settings` on those
    /// where something gets corrected. Photos where neither side is found (and `force` is off) get no fix.
    /// One undo step for all of them; a toast says how many were fixed.
    func applyBandFix(_ ids: [String], settings: BandFixSettings = .init()) {
        let items = ids.compactMap { byID[$0] }
        guard !items.isEmpty else { return }
        toast = items.count == 1 ? "Looking for shutter bands…" : "Looking for shutter bands on \(items.count) photos…"
        let jobs = items.map { ($0.id, $0.url) }
        let folder = self.folder
        Task { [weak self] in
            var found: [String] = []
            await withTaskGroup(of: (String, Bool).self) { group in
                var next = 0
                func add() {
                    let (id, url) = jobs[next]
                    next += 1
                    group.addTask(priority: .userInitiated) {
                        let a = await BandFixStore.shared.analysis(url: url, settings: settings, onScreen: true)   // asked for: before the background check
                        return (id, a?.changesImage ?? false)
                    }
                }
                for _ in 0..<min(3, jobs.count) { add() }
                for await (id, fixes) in group {
                    if fixes { found.append(id) }
                    if next < jobs.count { add() }
                }
            }
            guard let self, self.folder == folder else { return }
            self.storeBandFix(found, settings: settings, of: items.count)
        }
    }

    private func storeBandFix(_ found: [String], settings: BandFixSettings, of total: Int) {
        let order = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($1.id, $0) })
        let changing = found.compactMap { byID[$0] }.filter { $0.bandFix != settings }.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        if !changing.isEmpty {
            let before = journalStates(changing.map(\.id))
            for p in changing {
                p.record(p.decision, correction: p.correction, label: p.bandFix == nil ? "Bands fixed" : "Band fix adjusted",
                         bandFix: .some(settings))
            }
            commit(changing.map(\.id), .bandFix, before: before,
                   summary: changing.count == 1 ? nil : "Fixed bands on \(changing.count) photos")
        }
        let clean = total - found.count
        if total == 1 {
            toast = found.isEmpty ? "No shutter bands found" : "Fixed the shutter bands"
        } else {
            toast = "Fixed bands on \(found.count) of \(total)" + (clean > 0 ? " (\(clean) clean)" : "")
        }
    }

    /// Opens the Fixes panel on a photo (Mac: in the preview; iPhone: the editor's sheet).
    func openFixes(_ id: String) {
        if openedID != id {
            if !navigation.contains(id) { navigation = visible.map(\.id); if !navigation.contains(id) { navigation = photos.map(\.id) } }
            openedID = id
        }
        if !selection.contains(id) { selection = [id] }
        quickLook = false
        levelTool = false
        fixesTool = true
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
        let state = Dictionary(uniqueKeysWithValues: photos.filter { $0.analyzed || $0.history.count > 1 || $0.favorite || !$0.cropVersions.isEmpty || $0.info != nil || $0.savedBandFix != nil }.map { ($0.id, $0.saved) })
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: folder.appendingPathComponent(Self.stateFileName), options: .atomic)
    }
}

// MARK: - Activity history (the folder's journal) and revert

extension Library {
    /// "DSCF0015" for "DSCF0015.JPG" (or "sub/DSCF0015.JPG").
    static func shortName(_ id: String) -> String { ((id as NSString).lastPathComponent as NSString).deletingPathExtension }

    /// A photo's state as the journal records it.
    func journalState(_ p: Photo) -> JournalState {
        func box(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }
        return JournalState(d: p.decision, c: p.correction, crop: p.crop.map(box), fav: p.favorite ? true : nil,
                            versions: p.cropVersions.isEmpty ? nil : p.cropVersions.map { .init(id: $0.id, r: box($0.rect), ratio: $0.ratio) },
                            chosen: p.chosenVersionID, band: p.bandFix)
    }

    func journalStates(_ ids: [String]) -> [String: JournalState] {
        var out: [String: JournalState] = [:]
        for id in ids { if let p = byID[id] { out[id] = journalState(p) } }
        return out
    }

    /// Appends one entry (off the main thread). By default only photos whose state changed are kept, and nothing
    /// changed means no entry. Returns the summary written.
    @discardableResult
    func logActivity(_ action: JournalAction, _ ids: [String], before: [String: JournalState], summary: String? = nil,
                     extra: JournalExtra? = nil, keepUnchanged: Bool = false) -> String? {
        guard let journal else { return nil }
        let after = journalStates(ids)
        let files = keepUnchanged ? ids : ids.filter { before[$0] != after[$0] }
        guard !files.isEmpty else { return nil }
        let keep = Set(files)
        let text = summary ?? describe(action, files, after: after)
        let b = before.filter { keep.contains($0.key) }, a = after.filter { keep.contains($0.key) }
        let entry = JournalEntry(action: action, files: files, summary: text,
                                 before: b.isEmpty ? nil : b, after: a.isEmpty ? nil : a, extra: extra)
        journal.append(entry)
        if activityOpen { activity.insert(entry, at: 0) }
        return text
    }

    /// "Leveled DSCF0015 −0.4°", "Kept 3 photos as shot"…
    func describe(_ action: JournalAction, _ files: [String], after: [String: JournalState]) -> String {
        let one = files.count == 1 ? Self.shortName(files[0]) : nil
        let subject = one ?? "\(files.count) photos"
        let angle = one == nil ? "" : after[files[0]].map { " " + Geometry.format($0.c) } ?? ""
        switch action {
        case .level: return "Leveled \(subject)\(angle)"
        case .keep: return "Kept \(subject) as shot"
        case .undecided: return "Marked \(subject) undecided"
        case .reset: return "Reset \(subject)"
        case .tilt: return "Suggested angle on \(subject)\(angle)"
        case .ruler: return "Rotated \(subject)\(angle)"
        case .twoPoint: return "Leveled \(subject) by two points\(angle)"
        case .nudge: return "Nudged \(subject)\(angle)"
        case .autoLevel: return "Auto-leveled \(subject)\(angle)"
        case .jump: return "Went back in the history of \(subject)"
        case .crop:
            guard let one, let s = after[files[0]] else { return "Cropped \(subject)" }
            guard let r = s.cropRect else { return "Removed the crop of \(one)" }
            let name = Self.cropName(r, aspect: byID[files[0]]?.analysisAspect ?? 1.5)
            return "Cropped \(one)" + (name.isEmpty ? "" : " " + name)
        case .versionAdd: return "Added a crop version to \(subject)"
        case .versionChoose: return "Chose a crop version for \(subject)"
        case .versionRemove: return "Removed a crop version from \(subject)"
        case .bandFix:
            guard let one else { return "Fixed bands on \(subject)" }
            return after[files[0]]?.band == nil ? "Removed the band fix from \(one)" : "Fixed bands on \(one)"
        case .favorite: return "Favorited \(subject)"
        case .unfavorite: return "Unfavorited \(subject)"
        case .delete: return "Moved \(subject) to the Trash"
        case .restoreFromTrash: return "Put back \(subject) from the Trash"
        case .saveToOriginal: return "Saved \(subject) to the original" + (one == nil ? "s" : "")
        case .restoreOriginal: return "Restored the original" + (one == nil ? "s of " : " of ") + subject
        case .addToPhotos: return "Added \(subject) to Photos"
        case .photosFavorites: return "Marked \(subject) as favorites in Photos"
        case .export: return "Exported \(subject)"
        case .undo, .redo, .revert, .other: return subject
        }
    }

    /// Export runs in the views (Mac sheet, iPhone ⋯); they report here when it's done.
    func noteExport(_ ids: [String], to destination: URL) {
        guard !ids.isEmpty else { return }
        logActivity(.export, ids, before: [:], summary: describe(.export, ids, after: [:]) + " to “\(destination.lastPathComponent)”",
                    extra: JournalExtra(destination: destination.path), keepUnchanged: true)
    }

    // MARK: Reading

    fileprivate func resetActivity(_ journal: Journal?) {
        self.journal = journal
        activity = []
        activityHasMore = false
        activityLoading = false
        activityOpen = false
        activityCursors = [:]
    }

    /// Reads the newest page (or, with `more`, the next older one) in the background.
    func loadActivity(more: Bool = false) {
        guard let journal, !activityLoading else { return }
        if !more { activity = []; activityCursors = [:] }
        activityOpen = true
        activityLoading = true
        let cursors = activityCursors
        Task {
            let page = await journal.page(after: cursors)
            guard self.journal === journal else { return }
            let known = Set(activity.map(\.id))
            activity = (activity + page.entries.filter { !known.contains($0.id) }).sorted { $0.date > $1.date }
            activityCursors = page.cursors
            activityHasMore = page.cursors.values.contains { $0 > 0 }
            activityLoading = false
        }
    }

    /// Selects and opens a photo from the history (switching to All if the current tab doesn't show it).
    func showPhoto(_ id: String) {
        guard let p = byID[id] else { toast = "\(Self.shortName(id)) isn't in this folder any more"; return }
        if !belongs(p, to: filter) { filter = .all }
        quickLook = false
        openPhoto(id)
    }

    // MARK: Revert

    /// Photos in the entry that changed again afterwards (their state now isn't what the entry left).
    func editedLater(_ e: JournalEntry) -> [String] {
        guard let after = e.after else { return [] }
        return e.files.filter { id in
            guard let p = byID[id], let a = after[id] else { return false }
            return journalState(p) != a
        }
    }

    /// The question to ask before reverting, or nil when nothing changed since.
    func revertWarning(_ e: JournalEntry) -> String? {
        guard e.action != .delete, e.action != .saveToOriginal else { return nil }
        let later = editedLater(e)
        guard !later.isEmpty else { return nil }
        return later.count == 1
            ? "\(Self.shortName(later[0])) was edited later — revert it to how it was before this change?"
            : "\(later.count) photos were edited later — revert them to how they were before this change?"
    }

    /// Undoes one history entry as a new step (itself undoable and logged): state changes go back to `before`,
    /// deletions come back from the Trash, saves to original are restored from the backup.
    func revert(_ e: JournalEntry) {
        switch e.action {
        case .delete: revertDelete(e)
        case .saveToOriginal: restoreOriginals(e.files, reverting: e)
        default:
            guard e.isRevertible, let before = e.before else { toast = e.notRevertibleNote ?? "This can't be reverted"; return }
            let ids = e.files.filter { byID[$0] != nil && before[$0] != nil }
            guard !ids.isEmpty else { toast = "Not in this folder any more"; return }
            let now = journalStates(ids)
            var stepped: [String] = []
            for id in ids {
                guard let p = byID[id], let s = before[id] else { continue }
                if apply(s, to: p, label: "Reverted") { stepped.append(id) }
            }
            #if os(macOS)
            let flipped = ids.filter { now[$0]?.isFavorite != before[$0]?.isFavorite }.compactMap { byID[$0] }
            for value in [true, false] {
                let urls = flipped.filter { $0.favorite == value }.flatMap { [$0.url] + $0.companions }
                if !urls.isEmpty { FinderTag.set(value, on: urls) }
            }
            #endif
            let text = logActivity(.revert, ids, before: now, summary: "Reverted: " + e.summary, extra: JournalExtra(revertOf: e.id))
            if !stepped.isEmpty {
                undoStack.append(.edit(stepped, text ?? "Revert"))
                redoStack.removeAll()
            }
            saveSoon()
            toast = text == nil ? "Already as it was" : "Reverted"
        }
    }

    /// Sets a photo to a recorded state. Decision, rotation and crop become a new history step (true if one was added).
    @discardableResult
    func apply(_ s: JournalState, to p: Photo, label: String) -> Bool {
        let index = p.index, count = p.history.count
        p.record(s.d, correction: s.c, label: label, crop: .some(s.cropRect), bandFix: .some(s.band))
        p.favorite = s.isFavorite
        let old = Dictionary(p.cropVersions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        p.cropVersions = (s.versions ?? []).compactMap { v in
            guard v.r.count == 4 else { return nil }
            var cv = old[v.id] ?? CropVersion(id: v.id, rect: .zero, ratio: v.ratio)
            cv.rect = CGRect(x: v.r[0], y: v.r[1], width: v.r[2], height: v.r[3])
            cv.ratio = v.ratio
            return cv
        }
        p.chosenVersionID = s.chosen
        return p.index != index || p.history.count != count
    }

    /// Moves a deletion's files back from the Trash (if they're still there) and puts the photos back.
    private func revertDelete(_ e: JournalEntry) {
        guard let moved = e.extra?.trashed, !moved.isEmpty else { return }
        let fm = FileManager.default
        let missing = e.files.filter { byID[$0] == nil }
        guard !missing.isEmpty else { toast = "Already back in the folder"; return }
        let groups = Dictionary(grouping: moved, by: \.photo)
        guard missing.contains(where: { id in groups[id]?.contains { fm.fileExists(atPath: $0.to) } ?? false }) else {
            toast = "Already emptied from the Trash"
            return
        }
        var back: [String] = [], skipped: [String] = []
        for id in missing {
            guard let files = groups[id], !files.isEmpty else { continue }
            let own = (id as NSString).lastPathComponent
            let primary = files.first { ($0.from as NSString).lastPathComponent == own } ?? files[0]
            func file(_ m: JournalExtra.Moved) -> TrashedFile {
                TrashedFile(original: URL(fileURLWithPath: m.from), trashed: URL(fileURLWithPath: m.to))
            }
            do { try Trash.restore(file(primary)) } catch {
                Self.log("revert put back \(own): \(error.localizedDescription)")
                skipped.append(Self.shortName(id))
                continue
            }
            var companions: [URL] = []
            for m in files where m != primary {
                do { try Trash.restore(file(m)); companions.append(URL(fileURLWithPath: m.from)) } catch {
                    skipped.append((m.from as NSString).lastPathComponent)
                }
            }
            // The same Photo (full history) if its deletion is still on the undo stack, else a new one set to `before`.
            let photo: Photo
            if let kept = takeDeleted(id) {
                photo = kept
            } else {
                photo = Photo(id: id, url: URL(fileURLWithPath: primary.from), companions: companions)
                if let s = e.before?[id] { apply(s, to: photo, label: "Put back") }
            }
            let at = photos.firstIndex { $0.id.localizedStandardCompare(id) == .orderedDescending } ?? photos.count
            photos.insert(photo, at: at)
            byID[id] = photo
            if photo.analyzed { analyzedCount += 1 }
            back.append(id)
        }
        guard !back.isEmpty else { toast = "Couldn't put back " + skipped.joined(separator: ", ") + " (taken or gone)"; return }
        undoableToast = nil
        selection = Set(back)
        logActivity(.revert, back, before: [:], summary: "Reverted: " + e.summary, extra: JournalExtra(revertOf: e.id), keepUnchanged: true)
        var text = back.count == 1 ? "Put back from the Trash" : "Put back \(back.count) from the Trash"
        if !skipped.isEmpty { text += " · skipped " + skipped.joined(separator: ", ") }
        toast = text
        saveNow()
        if !isAnalyzing, back.contains(where: { byID[$0]?.analyzed == false }) { analyze() }
    }

    /// Takes a photo out of the deletions still on the undo stack (so ⌘Z won't try to put it back twice).
    private func takeDeleted(_ id: String) -> Photo? {
        for (i, step) in undoStack.enumerated() {
            guard case .delete(let d) = step, let item = d.items.first(where: { $0.photo.id == id }) else { continue }
            let rest = d.items.filter { $0.photo.id != id }
            if rest.isEmpty { undoStack.remove(at: i) } else { undoStack[i] = .delete(Deletion(items: rest, openedID: d.openedID)) }
            return item.photo
        }
        return nil
    }
}

#if os(macOS)
/// Favorites in Finder: the system Red tag ("Red" is matched to it, stored as "Red\n6" with the red label).
/// Other tags are kept. Errors (read-only cards) are only logged.
enum FinderTag {
    static let favorite = "Red"

    static func has(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []).contains(favorite)
    }

    static func set(_ value: Bool, on urls: [URL]) {
        Task.detached(priority: .utility) {
            for url in urls {
                var tags = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
                guard tags.contains(favorite) != value else { continue }
                if value { tags.append(favorite) } else { tags.removeAll { $0 == favorite } }
                do { try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
                catch { Library.log("tag \(url.lastPathComponent): \(error.localizedDescription)") }
            }
        }
    }
}
#endif
