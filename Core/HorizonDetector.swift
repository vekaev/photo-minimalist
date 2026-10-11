import CoreGraphics
import Foundation
import Vision

public struct Detection: Codable, Equatable, Sendable {
    /// Tilt of the horizon in the photo: degrees, counter-clockwise positive.
    public var angle: Double
    public var confidence: Double
    public var correction: Double { -angle }

    public init(angle: Double, confidence: Double) {
        self.angle = angle
        self.confidence = confidence
    }
}

public enum HorizonDetector {
    /// Pixel size used for analysis. Large enough for Vision, small enough to stay fast on RAW files.
    public static let analysisSize = 1024

    public static func detect(_ image: CGImage) throws -> Detection? {
        let request = VNDetectHorizonRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let observation = request.results?.first else { return nil }
        // Vision reports the rotation that levels the photo; flip it to get the tilt.
        return Detection(angle: -Double(observation.angle) * 180 / .pi, confidence: Double(observation.confidence))
    }

    public static func detect(url: URL) -> Detection? {
        guard let image = ImageLoader.thumbnail(url, maxPixel: analysisSize) else { return nil }
        return try? detect(image)
    }
}
