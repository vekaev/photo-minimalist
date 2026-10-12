import CoreGraphics
import Foundation
import Vision

public struct Detection: Codable, Equatable, Sendable {
    /// Suggested tilt of the photo: degrees, counter-clockwise positive.
    public var angle: Double
    /// Kept for older saved files; Vision reports ~1.0 for everything, so it isn't shown.
    public var confidence: Double
    /// Which detector(s) produced the suggestion: "horizon" (Vision), "lines" (straight edges) or "both".
    public var source: String?
    /// True when the suggestion is trustworthy enough to put first ("Looks tilted"), false for "Maybe tilted".
    public var likely: Bool?
    /// The raw readings, for showing why.
    public var horizonAngle: Double?
    public var lineAngle: Double?
    public var lineStrength: Double?

    public var correction: Double { -angle }
    /// "Looks tilted" vs "Maybe tilted". Over 5° is usually a deliberate angle (portraits, dutch angles)
    /// or perspective, so it never counts as likely, whatever the detectors say.
    public var isLikely: Bool { (likely ?? true) && abs(angle) <= 5 }

    /// A tilt we're sure enough about to mention at all. Everything else stays silent in the UI (the numbers are kept).
    /// Calibrated on the owner's card (969 photos, v3 readings): this suggests ~17 % of them, down from 62 %.
    /// - Vision's horizon and the line detector agree within 1°, and the tilt is 0.5…8°; or
    /// - Vision says nothing (it skips tilts under ~1°), the lines are a strong consensus (≥ 0.75) and the tilt is
    ///   small, 0.5…1.5° (bigger line-only tilts are too often scene structure).
    public var isConfident: Bool { Self.confident(horizon: horizonAngle, lines: lineAngle, strength: lineStrength) }

    public static let agreeDegrees = 1.0
    public static let minConfidentTilt = 0.5
    public static let maxConfidentTilt = 8.0
    public static let strongLines = 0.75
    public static let maxLinesOnlyTilt = 1.5

    public static func confident(horizon h: Double?, lines l: Double?, strength: Double?) -> Bool {
        guard let l else { return false }
        let tilt = abs(l)
        if let h {
            return abs(h) <= maxConfidentTilt && abs(h - l) <= agreeDegrees
                && tilt >= minConfidentTilt && tilt <= maxConfidentTilt
        }
        return (strength ?? 0) >= strongLines && tilt >= minConfidentTilt && tilt <= maxLinesOnlyTilt
    }

    public init(angle: Double, confidence: Double, source: String? = nil, likely: Bool? = nil,
                horizonAngle: Double? = nil, lineAngle: Double? = nil, lineStrength: Double? = nil) {
        self.angle = angle
        self.confidence = confidence
        self.source = source
        self.likely = likely
        self.horizonAngle = horizonAngle
        self.lineAngle = lineAngle
        self.lineStrength = lineStrength
    }
}

public enum HorizonDetector {
    /// Bump when detection changes, so saved results get re-checked once.
    /// 3: line segments with a consensus rule (LightCraft port) replace the edge-orientation histogram.
    /// 4: only confident tilts are suggested (`Detection.isConfident`).
    public static let version = 4
    /// Pixel size used for analysis. Large enough for both detectors, small enough to stay fast.
    public static let analysisSize = 1024

    /// Vision's horizon only. Vision returns nothing for tilts under ~1° and for photos without a horizon.
    public static func detect(_ image: CGImage) throws -> Detection? {
        let request = VNDetectHorizonRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let observation = request.results?.first else { return nil }
        // Vision reports the rotation that levels the photo; flip it to get the tilt.
        let a = -Double(observation.angle) * 180 / .pi
        return Detection(angle: a, confidence: Double(observation.confidence), source: "horizon", horizonAngle: a)
    }

    /// Both detectors, combined into one honest suggestion (or none).
    public static func analyze(_ image: CGImage) -> Detection? {
        let horizon = (try? detect(image)).flatMap { $0 }?.angle
        let lines = LineTilt.estimate(image)
        return combine(horizon: horizon, lines: lines)
    }

    /// Rules, from checking real photos: either detector alone gets fooled (portraits, perspective, interiors),
    /// readings beyond ±8° are mostly wrong, and agreement between the two is the best sign of a real tilt.
    ///
    /// Since version 3 a line estimate only exists when at least half of the line length agrees within 2°
    /// (`LineTilt`), so its `strength` is 0.5…1; 0.6 and up counts as strong. Lines are also far more precise than
    /// Vision (which reports in coarse steps), so when the two agree the line angle is used.
    static func combine(horizon: Double?, lines: LineTilt.Estimate?) -> Detection? {
        let maxPlausible = 8.0
        let h = horizon.flatMap { abs($0) <= maxPlausible ? $0 : nil }
        let strongLines = lines.flatMap { $0.strength >= 0.6 && abs($0.angle) <= 6 ? $0 : nil }
        let anyLines = lines.flatMap { abs($0.angle) <= maxPlausible ? $0 : nil }
        func make(_ a: Double, _ src: String, _ likely: Bool) -> Detection {
            Detection(angle: a, confidence: lines?.strength ?? 1, source: src, likely: likely,
                      horizonAngle: horizon, lineAngle: lines?.angle, lineStrength: lines?.strength)
        }
        switch (h, anyLines) {
        case let (h?, l?) where abs(h - l.angle) <= 1.5:
            return make(l.angle, "both", true)
        case let (h?, l?):
            // They disagree: trust strong lines over the horizon, but only as a "maybe".
            return strongLines != nil ? make(l.angle, "lines", false) : make(h, "horizon", false)
        case let (h?, nil):
            return make(h, "horizon", false)
        case let (nil, l?):
            // Lines alone: strong consensus within ±6° is "likely", the rest a "maybe".
            return make(l.angle, "lines", strongLines != nil)
        case (nil, nil):
            return nil
        }
    }

    /// Loads a fast preview for analysis: the RAW's embedded preview when there is one (2–3× faster than
    /// decoding a large JPEG from a memory card), else the image itself.
    public static func detect(url: URL, rawCompanion: URL? = nil) -> Detection? {
        analysisImage(url: url, rawCompanion: rawCompanion).flatMap(analyze)
    }

    public static func analysisImage(url: URL, rawCompanion: URL?) -> CGImage? {
        rawCompanion.flatMap { ImageLoader.thumbnail($0, maxPixel: analysisSize) }
            ?? ImageLoader.thumbnail(url, maxPixel: analysisSize)
    }
}
