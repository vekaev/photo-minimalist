import Foundation

/// One file moved out of the photo folder: where it was, and where it is now.
struct TrashedFile {
    let original: URL
    let trashed: URL
}

/// A photo taken out of the library by "Move to Trash", with everything needed to put it back.
struct DeletedPhoto {
    let photo: Photo
    /// Position in `Library.photos` and in the visible list when it was deleted.
    let index: Int
    let navIndex: Int?
    let files: [TrashedFile]
}

/// One "Move to Trash" (one ⌘Z step).
struct Deletion {
    let items: [DeletedPhoto]
    let openedID: String?
}

/// Moves files to the Trash and back. Nothing here ever deletes a file.
enum Trash {
    /// Where files go when the volume or file provider has no Trash (some iOS providers), so undo still works.
    static let fallbackFolderName = ".horizonleveler-trash"

    /// Moves `url` to the Trash, or into `<folder>/.horizonleveler-trash/` if the Trash isn't available.
    /// Returns the file's new location.
    static func move(_ url: URL, folder: URL?) throws -> URL {
        let fm = FileManager.default
        do {
            var out: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &out)
            return (out as URL?) ?? url
        } catch {
            guard let folder else { throw error }
            // A folder per file, so two files with the same name never collide.
            let dir = folder.appendingPathComponent(fallbackFolderName, isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(url.lastPathComponent)
            try fm.moveItem(at: url, to: dest)
            return dest
        }
    }

    /// Moves a file back. Fails (and leaves everything as is) if the original path is taken or the file is gone.
    static func restore(_ f: TrashedFile) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: f.original.path) else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: f.original.path]) }
        guard fm.fileExists(atPath: f.trashed.path) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: f.trashed.path]) }
        try fm.moveItem(at: f.trashed, to: f.original)
        // Tidy our own fallback folder: rmdir only removes a directory that is already empty.
        let parent = f.trashed.deletingLastPathComponent()
        if parent.deletingLastPathComponent().lastPathComponent == fallbackFolderName {
            rmdir(parent.path)
            rmdir(parent.deletingLastPathComponent().path)
        }
    }
}
