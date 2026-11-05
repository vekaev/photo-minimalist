import Foundation

/// A copy, on the Mac, of the memory-card folder that was open last: its photo list, each photo's size and date
/// (the keys of the thumbnail cache) and its saved decisions. When a card touches the SD slot, macOS needs
/// ~4.5 s before the card can be read; this lets the photos show at once from the Mac's caches, read-only,
/// until the real folder is mounted and replaces it (`Library.openPreview`, `WindowRouter.cardDetected`).
/// Only the last card folder is kept: `~/Library/Application Support/HorizonLeveler/card-snapshot.json`.
struct CardSnapshot: Codable {
    struct File: Codable {
        var path: String
        var size: Int
        var modified: Double
        var companions: [String]
    }
    var folder: String
    var files: [File]
    var state: Data

    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HorizonLeveler/card-snapshot.json")
    }

    static func load() -> CardSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CardSnapshot.self, from: data)
    }

    // MARK: Keeping it current

    /// The listing part, taken once per open (stats ~1.7 k files on the card, off the main thread).
    nonisolated(unsafe) private static var files: (folder: String, files: [File])?
    private static let queue = DispatchQueue(label: "app.horizonleveler.card-snapshot", qos: .utility)

    /// After a card folder opened: remember its files, then write the snapshot with this state.
    static func capture(folder: URL, photos: [(url: URL, companions: [URL])], state: Data) {
        queue.async {
            guard (try? folder.resourceValues(forKeys: [.volumeIsRemovableKey]).volumeIsRemovable) == true else {
                files = nil; return
            }
            let list = photos.compactMap { p -> File? in
                guard let v = try? p.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                return File(path: p.url.path, size: v.fileSize ?? 0, modified: v.contentModificationDate?.timeIntervalSince1970 ?? 0,
                            companions: p.companions.map(\.path))
            }
            files = (folder.path, list)
            write(folder: folder.path, state: state)
        }
    }

    /// The folder's decisions changed (Library.saveNow): refresh the state part.
    static func update(folder: URL, state: Data) {
        queue.async {
            guard files?.folder == folder.path else { return }
            write(folder: folder.path, state: state)
        }
    }

    private static func write(folder: String, state: Data) {
        guard let files, files.folder == folder else { return }
        let snapshot = CardSnapshot(folder: folder, files: files.files, state: state)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
