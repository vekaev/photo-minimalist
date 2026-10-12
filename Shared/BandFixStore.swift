import CoreGraphics
import Foundation
import ImageIO

/// What a view needs to show a photo with its film scan fix: the file and the settings.
struct BandFixSource: Equatable, Sendable {
    let url: URL
    let settings: BandFixSettings
}

extension Photo {
    /// The band fix to draw on screen, or nil when the photo has none.
    var bandFixSource: BandFixSource? { bandFix.map { BandFixSource(url: url, settings: $0) } }
}

/// On-screen side of the Band Fixer (`Core/BandFixer.swift`): one analysis per photo, made from the same pixels
/// export uses (the full JPEG / HEIC / TIFF; a RAW without a JPEG uses its large embedded preview), kept in memory
/// and re-planned for new settings without touching the file (`BandAnalysis.updated`). The resulting 1-D gain is
/// applied to whatever preview or thumbnail is on screen; fixed images are cached per photo + size + settings.
final class BandFixStore: @unchecked Sendable {
    static let shared = BandFixStore()

    private let lock = NSLock()
    /// Base analyses (with whatever settings they were first made), most recently used last. Each holds the
    /// 772-px log-luminance map (~3 MB), so only a few are kept.
    private var bases: [URL: BandAnalysis] = [:]
    private var lru: [URL] = []
    private let maxBases = 24
    /// The last re-planned analysis per photo (dragging a slider re-plans from it, not from scratch).
    private var derived: [URL: BandAnalysis] = [:]
    /// The gain per photo + settings: tiny, so thumbnails never need the analysis again.
    private var gains: [String: Gain] = [:]
    private var inflight: [URL: Task<BandAnalysis?, Never>] = [:]
    private let images = NSCache<NSString, CGImage>()

    struct Gain: Sendable {
        let logGain: [Double]
        let portrait: Bool
        let changes: Bool
    }

    init() { images.totalCostLimit = 400 * 1024 * 1024 }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    /// Forget everything about a file that changed on disk (save to original, restore).
    func evict(_ url: URL) {
        locked {
            bases[url] = nil
            derived[url] = nil
            lru.removeAll { $0 == url }
            gains = gains.filter { !$0.key.hasPrefix(url.path + "|") }
        }
        images.removeAllObjects()
    }

    static func settingsKey(_ s: BandFixSettings) -> String {
        let r = s.rows.map { String(format: "%.4f-%.4f", $0.lowerBound, $0.upperBound) } ?? "auto"
        return String(format: "%.4f|%.4f|%.4f|%.4f|%.4f|%.5f|%d|", s.left, s.right, s.flatten, s.zoneLeft, s.zoneRight, s.tilt, s.force ? 1 : 0) + r
    }

    private static func gainKey(_ url: URL, _ s: BandFixSettings) -> String {
        // Tilt is applied with the gain, it doesn't change it.
        var g = s
        g.tilt = 0
        return url.path + "|" + settingsKey(g)
    }

    // MARK: Analysis

    /// The analysis for `settings`: from memory if possible, else the file is read (through the ReadGate) and analysed.
    func analysis(url: URL, settings: BandFixSettings, onScreen: Bool = true) async -> BandAnalysis? {
        if let hit = cachedAnalysis(url: url, settings: settings) { return hit }
        let task: Task<BandAnalysis?, Never> = locked {
            if let t = inflight[url] { return t }
            let t = Task.detached(priority: onScreen ? .userInitiated : .utility) { () -> BandAnalysis? in
                await ReadGate.shared.enter(onScreen: onScreen)
                let image = Self.load(url)
                await ReadGate.shared.leave()
                return image.map { BandFixer.analyze(cgImage: $0, settings: settings) }
            }
            inflight[url] = t
            return t
        }
        let base = await task.value
        locked {
            inflight[url] = nil
            if let base, bases[url] == nil {
                bases[url] = base
                lru.append(url)
                while lru.count > maxBases { let old = lru.removeFirst(); bases[old] = nil; derived[old] = nil }
            }
        }
        guard base != nil else { return nil }
        return cachedAnalysis(url: url, settings: settings)
    }

    /// Without touching the file: nil when this photo hasn't been analysed (or was dropped from memory).
    func cachedAnalysis(url: URL, settings: BandFixSettings) -> BandAnalysis? {
        let (base, last) = locked { () -> (BandAnalysis?, BandAnalysis?) in
            guard let b = bases[url] else { return (nil, nil) }
            lru.removeAll { $0 == url }
            lru.append(url)
            return (b, derived[url])
        }
        guard let base else { return nil }
        if base.settings == settings { remember(url, base); return base }
        if let last, last.settings == settings { return last }
        let a = (last ?? base).updated(settings)
        locked { derived[url] = a }
        remember(url, a)
        return a
    }

    private func remember(_ url: URL, _ a: BandAnalysis) {
        let key = Self.gainKey(url, a.settings)
        locked {
            if gains[key] == nil {
                if gains.count > 4000 { gains.removeAll() }
                gains[key] = Gain(logGain: a.logGain, portrait: a.portrait, changes: a.changesImage)
            }
        }
    }

    private func gain(url: URL, settings: BandFixSettings) async -> Gain? {
        if let g = locked({ gains[Self.gainKey(url, settings)] }) { return g }
        guard let a = await analysis(url: url, settings: settings) else { return nil }
        return Gain(logGain: a.logGain, portrait: a.portrait, changes: a.changesImage)
    }

    /// The pixels export analyses (`Renderer.bandFixed`): the full upright file; a RAW uses its embedded preview.
    static func load(_ url: URL) -> CGImage? {
        if ImageLoader.isRaw(url) { return ImageLoader.thumbnail(url, maxPixel: 2400) }
        return BandFixer.loadOriented(url)
    }

    // MARK: Fixed images for the screen

    private static func imageKey(_ image: CGImage, _ source: BandFixSource) -> NSString {
        "\(source.url.path)|\(image.width)x\(image.height)|\(settingsKey(source.settings))" as NSString
    }

    /// A fixed version already made, without waiting (no flash of the unfixed photo while scrolling).
    func cachedFixed(_ image: CGImage, _ source: BandFixSource) -> CGImage? {
        images.object(forKey: Self.imageKey(image, source))
    }

    /// `image` (any preview or thumbnail of the photo, upright) with the band fix applied. Returns `image` itself
    /// when the fix changes nothing, nil when the photo can't be read.
    func fixed(_ image: CGImage, _ source: BandFixSource) async -> CGImage? {
        let key = Self.imageKey(image, source)
        if let hit = images.object(forKey: key) { return hit }
        guard let g = await gain(url: source.url, settings: source.settings) else { return nil }
        if Task.isCancelled { return nil }
        let tilt = source.settings.tilt
        let out: CGImage = g.changes
            ? await Task.detached(priority: .userInitiated) {
                BandFixer.apply(gain: g.logGain, to: image, tilt: tilt, portrait: g.portrait)
            }.value
            : image
        images.setObject(out, forKey: key, cost: out.bytesPerRow * out.height)
        return out
    }

    /// Downscaled copies for live previews, matched by identity of the source image (a few, newest last).
    private var live: [(source: CGImage, maxPixel: Int, image: CGImage)] = []

    /// `image` scaled to at most `maxPixel` (made once per preview image), so slider changes apply quickly.
    func liveBase(_ image: CGImage, maxPixel: Int) -> CGImage {
        if max(image.width, image.height) <= maxPixel { return image }
        if let hit = locked({ live.first { $0.source === image && $0.maxPixel == maxPixel }?.image }) { return hit }
        let small = Self.downscaled(image, maxPixel: maxPixel)
        locked {
            live.append((image, maxPixel, small))
            if live.count > 4 { live.removeFirst() }
        }
        return small
    }

    /// Scales an image down so its long side is at most `maxPixel` (for live slider previews).
    static func downscaled(_ image: CGImage, maxPixel: Int) -> CGImage {
        let s = Double(maxPixel) / Double(max(image.width, image.height))
        guard s < 1 else { return image }
        let w = max(1, Int(Double(image.width) * s)), h = max(1, Int(Double(image.height) * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
