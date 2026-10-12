import Foundation
import ImageIO
import Photos

/// Apple Photos ignores Finder tags and XMP ratings, so favorites go there through PhotoKit.
/// Only ever run on the owner's action.
enum PhotosSync {
    struct Item: Sendable {
        let url: URL
        let raw: URL?
        let favorite: Bool
    }

    enum Failure: LocalizedError {
        case denied
        var errorDescription: String? { "No access to Photos. Allow it in System Settings → Privacy & Security → Photos." }
    }

    static func authorize() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw Failure.denied }
    }

    /// Imports the original files (never a render): the JPEG as the photo and its RAW as the alternate,
    /// one asset like the camera makes. Favorites arrive as favorites. Returns how many were added.
    static func add(_ items: [Item]) async throws -> Int {
        try await authorize()
        var added = 0
        // Small batches: one change block per file set keeps memory flat and a bad file from sinking the rest.
        for chunk in stride(from: 0, to: items.count, by: 10).map({ Array(items[$0..<min($0 + 10, items.count)]) }) {
            try await PHPhotoLibrary.shared().performChanges {
                for item in chunk {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: item.url, options: options(item.url))
                    if let raw = item.raw { request.addResource(with: .alternatePhoto, fileURL: raw, options: options(raw)) }
                    request.isFavorite = item.favorite
                }
            }
            added += chunk.count
        }
        return added
    }

    private static func options(_ url: URL) -> PHAssetResourceCreationOptions {
        let o = PHAssetResourceCreationOptions()
        o.originalFilename = url.lastPathComponent
        o.shouldMoveFile = false
        return o
    }

    /// Marks already-imported copies of these files as favorites in Photos. Matches by original file name and
    /// capture date: one fetch over the date range, then names in memory. Only sets favorite, never clears it.
    /// Returns how many assets were matched.
    static func syncFavorites(_ urls: [URL]) async throws -> Int {
        try await setFavorite(urls, to: true)
    }

    /// Sets (or clears) the Photos favorite on already-imported copies of these files — the ♥ in this app mirrored
    /// as you press F. Same matching as above. Photos not in the library are left alone. Returns matches.
    @discardableResult
    static func setFavorite(_ urls: [URL], to value: Bool) async throws -> Int {
        try await authorize()
        let wanted = urls.map { (name: $0.lastPathComponent.lowercased(), date: captureDate($0)) }
        guard !wanted.isEmpty else { return 0 }
        let options = PHFetchOptions()
        let dates = wanted.compactMap(\.date)
        if let lo = dates.min(), let hi = dates.max() {
            // A day of slack each side: EXIF dates carry no time zone.
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                            lo.addingTimeInterval(-86_400) as NSDate, hi.addingTimeInterval(86_400) as NSDate)
        }
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var byName: [String: [PHAsset]] = [:]
        let names = Set(wanted.map(\.name))
        assets.enumerateObjects { asset, _, _ in
            for r in PHAssetResource.assetResources(for: asset) where r.type == .photo || r.type == .alternatePhoto {
                let n = r.originalFilename.lowercased()
                if names.contains(n) { byName[n, default: []].append(asset); break }
            }
        }
        // Same name (cameras reuse them every 10,000 shots): the asset closest in time, within ~a day.
        var matches: [PHAsset] = []
        for w in wanted {
            guard let candidates = byName[w.name] else { continue }
            let best = candidates.min { a, b in
                distance(a, w.date) < distance(b, w.date)
            }
            if let best, distance(best, w.date) <= 26 * 3600, !matches.contains(best) { matches.append(best) }
        }
        let toChange = matches.filter { $0.isFavorite != value }
        if !toChange.isEmpty {
            try await PHPhotoLibrary.shared().performChanges {
                for asset in toChange { PHAssetChangeRequest(for: asset).isFavorite = value }
            }
        }
        return matches.count
    }

    private static func distance(_ asset: PHAsset, _ date: Date?) -> TimeInterval {
        guard let date, let created = asset.creationDate else { return 0 }
        return abs(created.timeIntervalSince(date))
    }

    /// EXIF capture date (header only), else the file's modification date.
    static func captureDate(_ url: URL) -> Date? {
        if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let d = f.date(from: text) { return d }
        }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
