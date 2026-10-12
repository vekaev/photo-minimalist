import CoreGraphics
import CryptoKit
import Foundation

// The folder's activity history ("like git log"): one JSON line per action in
// `<folder>/.horizonleveler-history.jsonl`. Append-only, never rewritten. On a read-only folder (locked card)
// lines go to Application Support/HorizonLeveler/history/<hash of the folder path>.jsonl instead.

/// What happened. Unknown values (from a newer version) decode as `.other`.
enum JournalAction: String, Codable, Sendable {
    case level, keep, undecided, reset
    /// Corrections: the suggested angle, the ruler, two points, [ ] nudges, automatic level, history jump.
    case tilt, ruler, twoPoint, nudge, autoLevel, jump
    case crop, versionAdd, versionChoose, versionRemove
    /// Film scan fix (shutter bands): added, adjusted or removed.
    case bandFix
    case favorite, unfavorite
    case delete, restoreFromTrash
    case saveToOriginal, restoreOriginal
    case addToPhotos, photosFavorites, export
    case undo, redo, revert
    case other

    init(from decoder: Decoder) throws {
        self = JournalAction(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

/// A photo's edit state, compact: decision, correction, crop, ♥, crop versions.
struct JournalState: Codable, Equatable, Sendable {
    var d: Decision
    var c: Double
    /// x, y, w, h (0…1 in the leveled frame).
    var crop: [Double]?
    var fav: Bool?
    var versions: [Version]?
    var chosen: UUID?
    /// Film scan fix settings (shutter bands); nil = none.
    var band: BandFixSettings?

    struct Version: Codable, Equatable, Sendable {
        var id: UUID
        var r: [Double]
        var ratio: String
    }

    var cropRect: CGRect? { crop.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil } }
    var isFavorite: Bool { fav ?? false }
}

/// Anything else an entry needs to be undone later.
struct JournalExtra: Codable, Equatable, Sendable {
    /// Delete: each file, where it was and where it went (Trash or the hidden fallback folder).
    var trashed: [Moved]?
    /// Save to original: where the untouched files are kept.
    var backups: [String]?
    /// Export: the folder the copies went to.
    var destination: String?
    /// Revert: the entry it undid.
    var revertOf: UUID?

    struct Moved: Codable, Equatable, Sendable {
        /// The photo (its id) this file belongs to; RAW twins share the JPEG's.
        var photo: String
        var from: String
        var to: String
    }
}

struct JournalEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date = Date()
    var action: JournalAction
    /// Photo ids (file names relative to the folder).
    var files: [String]
    var summary: String
    var before: [String: JournalState]?
    var after: [String: JournalState]?
    var extra: JournalExtra?

    /// Revert can undo it: state changes, deletions (while the files are still in the Trash), saves to original.
    var isRevertible: Bool {
        switch action {
        case .addToPhotos, .photosFavorites, .export, .restoreOriginal, .restoreFromTrash, .other: return false
        case .delete: return !(extra?.trashed ?? []).isEmpty
        case .saveToOriginal: return true
        default: return !(before ?? [:]).isEmpty
        }
    }

    /// Why there's no Revert button.
    var notRevertibleNote: String? {
        switch action {
        case .addToPhotos, .photosFavorites: return "The photos in Apple Photos stay."
        case .export: return "Files in the export folder stay."
        case .restoreOriginal: return "Save to original again to redo it."
        case .restoreFromTrash: return "Move it to the Trash again to undo this."
        default: return nil
        }
    }
}

/// Appends entries off the main thread (one serial queue) and reads them back newest first, a page at a time.
final class Journal: @unchecked Sendable {
    static let fileName = ".horizonleveler-history.jsonl"

    let folder: URL
    let primary: URL
    let fallback: URL
    private let queue = DispatchQueue(label: "app.horizonleveler.journal", qos: .utility)
    /// Set (on the queue) once writing into the folder failed: from then on lines go to `fallback`.
    private var redirected = false

    init(folder: URL, fallbackRoot: URL? = nil) {
        self.folder = folder
        primary = folder.appendingPathComponent(Self.fileName)
        fallback = Self.fallbackURL(for: folder, root: fallbackRoot)
    }

    /// `~/Library/Application Support/HorizonLeveler/history/<hash>.jsonl` (iOS: the app's Application Support).
    static func fallbackURL(for folder: URL, root: URL? = nil) -> URL {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HorizonLeveler", isDirectory: true).appendingPathComponent("history", isDirectory: true)
        let hash = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent(hash + ".jsonl")
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func append(_ entry: JournalEntry) {
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(0x0A)
        queue.async { [self] in
            if !redirected {
                if Self.write(line, to: primary) { return }
                redirected = true
                Library.log("history: \(primary.path) not writable, using \(fallback.path)")
            }
            try? FileManager.default.createDirectory(at: fallback.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !Self.write(line, to: fallback) { Library.log("history: couldn't write \(fallback.path)") }
        }
    }

    /// Waits for queued lines to be written (tests, quitting).
    func flush() { queue.sync {} }

    /// Appends one line; a previous line cut short (crash mid-write) gets its newline first, so lines never merge.
    private static func write(_ line: Data, to url: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path), !fm.createFile(atPath: url.path, contents: nil) { return false }
        guard let h = try? FileHandle(forUpdating: url) else { return false }
        defer { try? h.close() }
        do {
            var data = line
            let end = try h.seekToEnd()
            if end > 0 {
                try h.seek(toOffset: end - 1)
                if let last = try h.read(upToCount: 1), last.first != 0x0A { data.insert(0x0A, at: 0) }
                try h.seekToEnd()
            }
            try h.write(contentsOf: data)
            return true
        } catch { return false }
    }

    // MARK: Reading (newest first, a page at a time)

    /// Where to continue in each file: the byte offset older lines end at (0 = nothing older). Missing = from the end.
    typealias Cursors = [String: UInt64]

    /// The next `limit` entries of each file (folder + fallback), merged newest first. Runs on the queue, so lines
    /// still waiting to be written are either all in or all out.
    func page(after cursors: Cursors, limit: Int = 200) async -> (entries: [JournalEntry], cursors: Cursors) {
        await withCheckedContinuation { done in
            queue.async { [self] in
                var all: [JournalEntry] = [], next = cursors
                for url in [primary, fallback] {
                    let key = url.path
                    if let c = cursors[key], c == 0 { continue }
                    guard let r = Self.readBackwards(url, before: cursors[key], limit: limit) else { next[key] = 0; continue }
                    all += r.entries
                    next[key] = r.start
                }
                done.resume(returning: (all.sorted { $0.date > $1.date }, next))
            }
        }
    }

    /// Reads up to `limit` lines ending at byte `end` (nil = end of file), newest first, without loading the whole
    /// file. `start` is the offset of the oldest line returned (0 = reached the beginning). Bad lines are skipped.
    static func readBackwards(_ url: URL, before end: UInt64?, limit: Int, chunk: Int = 64 * 1024) -> (entries: [JournalEntry], start: UInt64)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        var pos = min(end ?? size, size)
        var buf: [UInt8] = []                       // bytes from `pos` up to the oldest line taken so far
        var lines: [(offset: UInt64, bytes: ArraySlice<UInt8>)] = []   // newest first
        while pos > 0, lines.count < limit {
            let n = UInt64(min(UInt64(chunk), pos))
            pos -= n
            guard (try? h.seek(toOffset: pos)) != nil, let d = try? h.read(upToCount: Int(n)) else { return nil }
            buf = [UInt8](d) + buf
            // Every piece after a newline is a whole line; the first piece is whole only at the start of the file.
            var pieces: [(Int, Int)] = []
            var s = 0
            for (i, b) in buf.enumerated() where b == 0x0A { pieces.append((s, i)); s = i + 1 }
            pieces.append((s, buf.count))
            let firstWhole = pos == 0 ? 0 : 1
            for k in stride(from: pieces.count - 1, through: firstWhole, by: -1) {
                let (a, b) = pieces[k]
                // Blank lines (the end of the file, stray newlines) are skipped.
                if buf[a..<b].allSatisfy({ $0 == 0x20 || $0 == 0x0D }) { continue }
                lines.append((pos + UInt64(a), buf[a..<b]))
            }
            buf = firstWhole == 1 ? Array(buf[pieces[0].0..<pieces[0].1]) : []
        }
        // Keep `limit` non-empty lines; the rest are read again by the next page.
        var entries: [JournalEntry] = [], start = pos + UInt64(buf.count), taken = 0, full = false
        for line in lines {
            if taken == limit { full = true; break }
            start = line.offset
            taken += 1
            if let e = try? decoder.decode(JournalEntry.self, from: Data(line.bytes)) { entries.append(e) }
        }
        if !full, pos == 0 { start = 0 }
        return (entries, start)
    }
}
