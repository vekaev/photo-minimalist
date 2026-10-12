import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageLoader {
    public static let extensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp",
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2",
        "pef", "srw", "3fr", "iiq", "erf", "mos", "x3f",
    ]

    /// File placed in folders this app exports into, so they are never re-imported.
    public static let exportMarker = ".horizonleveler-export"

    public static func listImages(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if FileManager.default.fileExists(atPath: url.appendingPathComponent(exportMarker).path) {
                    walker.skipDescendants()
                }
                continue
            }
            if values?.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public static func isRaw(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) ?? false
    }

    /// Orientation-corrected downscaled image. For RAW files the camera's embedded preview is used when it's
    /// big enough, which is many times faster than decoding the RAW itself.
    /// - Parameter embeddedAtLeast: accept a file's embedded thumbnail if it's at least this big (any format).
    public static func thumbnail(_ url: URL, maxPixel: Int, embeddedAtLeast: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        func make(always: Bool) -> CGImage? {
            let options: [CFString: Any] = [
                always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        let minimum = embeddedAtLeast ?? (isRaw(url) ? min(maxPixel, 1000) : nil)
        if let minimum, let embedded = make(always: false), max(embedded.width, embedded.height) >= minimum {
            return embedded
        }
        return make(always: true)
    }

    public struct Group: Sendable {
        /// The file shown and analyzed (the JPEG of a RAW + JPEG pair).
        public let primary: URL
        /// Files with the same name in the same folder that travel with it (the RAW).
        public let companions: [URL]
    }

    /// Pairs RAW files with a JPEG / HEIC of the same name in the same folder, e.g. DSCF0015.JPG + DSCF0015.RAF.
    /// RAWs without such a partner stay on their own.
    public static func pairRawWithJPEG(_ urls: [URL]) -> [Group] {
        var buckets: [String: [URL]] = [:]
        for url in urls {
            let key = url.deletingPathExtension().standardizedFileURL.path.lowercased()
            buckets[key, default: []].append(url)
        }
        let rank: [String: Int] = ["jpg": 0, "jpeg": 0, "heic": 1, "heif": 1]
        var companionsOf: [URL: [URL]] = [:]
        var hidden: Set<URL> = []
        for files in buckets.values where files.count > 1 {
            let raws = files.filter(isRaw)
            guard !raws.isEmpty,
                  let main = files.filter({ !isRaw($0) }).min(by: { (rank[$0.pathExtension.lowercased()] ?? 9) < (rank[$1.pathExtension.lowercased()] ?? 9) })
            else { continue }
            companionsOf[main] = raws
            hidden.formUnion(raws)
        }
        return urls.filter { !hidden.contains($0) }.map { Group(primary: $0, companions: companionsOf[$0] ?? []) }
    }
}
