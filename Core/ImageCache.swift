import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Previews for the UI, built from the cheapest source that's good enough and kept in two places:
/// memory (capped by size, not count; full-size previews are ~24 MB each) and a disk cache on the Mac's own
/// drive, so reopening a folder on a memory card doesn't read the card again.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let memory = NSCache<NSString, CGImage>()
    private let folder: URL
    /// Previews up to this size are stored on disk (list and grid thumbnails).
    private let diskLimit = 480

    init() {
        memory.totalCostLimit = 700 * 1024 * 1024
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HorizonLeveler/previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Forget everything cached for a file that changed on disk (the disk cache keys on size and date already).
    func evict(_ url: URL) {
        for size in [3000, 2400, 1200, 420, 360, 160] { memory.removeObject(forKey: "\(size)|\(url.path)" as NSString) }
    }

    /// The sharpest version already in memory, without waiting: lets a view open with a picture instead of blank.
    func cached(for url: URL, sizes: [Int] = [3000, 2400, 1200, 420, 360, 160]) -> CGImage? {
        for size in sizes {
            if let hit = memory.object(forKey: "\(size)|\(url.path)" as NSString) { return hit }
        }
        return nil
    }

    /// - Parameter rawCompanion: a RAW next to the JPEG; its embedded preview loads 2–3× faster than the JPEG.
    func image(for url: URL, rawCompanion: URL? = nil, maxPixel: Int) async -> CGImage? {
        let key = "\(maxPixel)|\(url.path)" as NSString
        if let hit = memory.object(forKey: key) { return hit }
        let diskLimit = diskLimit, folder = folder
        // Cheap first: the disk cache, or the JPEG's tiny embedded thumbnail.
        let quick = await Task.detached(priority: .userInitiated) { () -> (CGImage?, URL?) in
            let diskURL = maxPixel <= diskLimit ? Self.diskURL(for: url, maxPixel: maxPixel, in: folder) : nil
            if let diskURL, let cached = Self.load(diskURL) { return (cached, diskURL) }
            if maxPixel <= 200 { return (ImageLoader.thumbnail(url, maxPixel: maxPixel, embeddedAtLeast: 100), diskURL) }
            return (nil, diskURL)
        }.value
        var image = quick.0
        if image == nil {
            // A real read from the card: wait for a turn, and give up if the thumbnail scrolled away meanwhile.
            await ReadGate.shared.enter(onScreen: true)
            if Task.isCancelled { await ReadGate.shared.leave(); return nil }
            image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let made = Self.make(url: url, raw: rawCompanion, maxPixel: maxPixel)
                if let made, let diskURL = quick.1 { Self.save(made, to: diskURL) }
                return made
            }.value
            await ReadGate.shared.leave()
        }
        if let image { memory.setObject(image, forKey: key, cost: image.bytesPerRow * image.height) }
        return image
    }

    /// Saves a grid thumbnail made from an image that was already loaded (the background check's preview),
    /// so the grid never reads that photo from the card again.
    func prime(url: URL, from image: CGImage, maxPixel: Int = 420) {
        guard let diskURL = Self.diskURL(for: url, maxPixel: maxPixel, in: folder),
              !FileManager.default.fileExists(atPath: diskURL.path),
              let small = Self.downscale(image, maxPixel: maxPixel) else { return }
        Self.save(small, to: diskURL)
    }

    private static func downscale(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let s = min(1, Double(maxPixel) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * s)), h = max(1, Int(Double(image.height) * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func make(url: URL, raw: URL?, maxPixel: Int) -> CGImage? {
        // Small list thumbnails: the JPEG's own embedded thumbnail (reads ~64 KB instead of the whole file).
        if maxPixel <= 200, let small = ImageLoader.thumbnail(url, maxPixel: maxPixel, embeddedAtLeast: 100) {
            return small
        }
        if let raw, let fromRaw = ImageLoader.thumbnail(raw, maxPixel: maxPixel) { return fromRaw }
        return ImageLoader.thumbnail(url, maxPixel: maxPixel)
    }

    /// Cache file named after the photo's path, size and modification date, so edits invalidate it.
    private static func diskURL(for url: URL, maxPixel: Int, in folder: URL) -> URL? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let id = "\(url.path)|\(v.fileSize ?? 0)|\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(maxPixel)"
        let hash = SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash + ".jpg")
    }

    private static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private static func save(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
