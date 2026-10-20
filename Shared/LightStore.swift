import CoreGraphics
import Foundation

/// What a view needs to show a photo with its light adjustment: which photo (so a new photo never shows the previous
/// one's picture while its own is being made) and the values.
struct LightSource: Equatable, Sendable {
    let url: URL
    let adjust: LightAdjust
}

extension Photo {
    /// The light adjustment to draw on screen, or nil when the photo has none.
    var lightSource: LightSource? { light.map { LightSource(url: url, adjust: $0) } }
}

/// On-screen side of `LightAdjust`: adjusted copies of whatever preview or thumbnail is on screen, made on the GPU
/// (~6 ms for a 3000 px preview, under 1 ms for a thumbnail) and cached per source image + values.
final class LightStore: @unchecked Sendable {
    static let shared = LightStore()

    /// Keeps its source alive, so the source's address (part of the key) can't be reused by another image.
    private final class Entry {
        let source: CGImage
        let image: CGImage
        init(source: CGImage, image: CGImage) { self.source = source; self.image = image }
    }

    private let images = NSCache<NSString, Entry>()

    init() { images.totalCostLimit = 300 * 1024 * 1024 }

    private static func key(_ source: CGImage, _ a: LightAdjust) -> NSString {
        "\(UInt(bitPattern: ObjectIdentifier(source).hashValue))|\(source.width)x\(source.height)|\(a.key)" as NSString
    }

    /// An adjusted copy already made, without waiting.
    func cached(_ source: CGImage, _ a: LightAdjust) -> CGImage? {
        guard let e = images.object(forKey: Self.key(source, a)), e.source === source else { return nil }
        return e.image
    }

    /// `source` with the adjustment (rendered off the main thread, then cached).
    func adjusted(_ source: CGImage, _ a: LightAdjust) async -> CGImage {
        if let hit = cached(source, a) { return hit }
        let out = await Task.detached(priority: .userInitiated) { LightAdjust.render(source, a) }.value
        images.setObject(Entry(source: source, image: out), forKey: Self.key(source, a), cost: out.bytesPerRow * out.height)
        return out
    }
}
