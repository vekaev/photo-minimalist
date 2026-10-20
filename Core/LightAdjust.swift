import CoreGraphics
import CoreImage
import Foundation

/// Basic light adjustments (like Apple Photos' "Light" or Lightroom's Basic panel), applied to the upright photo
/// after the film-scan band fix and before leveling / crop. Every value is 0 at rest; all zero = no change.
///
/// - exposure: EV stops, −2…+2 (`CIExposureAdjust`, in linear light: +1 doubles the light).
/// - brightness: −1…+1, a midtone lift / drop that keeps black and white where they are (a gamma curve in
///   display space: +1 = power 0.6, −1 = power 1.6). Unlike an offset it never greys the blacks.
/// - contrast: −1…+1, an S-curve around middle grey in display space (quarter tones move by up to 0.1).
/// - highlights: −1…+1, negative is a soft shoulder that recovers bright areas (also ones pushed past white by
///   exposure), positive lifts the upper tones; white stays white.
/// - shadows: −1…+1, positive opens up the dark quarter, negative deepens it; black stays black.
/// All but exposure are global curves (no local halos), so previews and exports match at any size.
public struct LightAdjust: Codable, Equatable, Hashable, Sendable {
    public var exposure: Double = 0
    public var brightness: Double = 0
    public var contrast: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0

    public init(exposure: Double = 0, brightness: Double = 0, contrast: Double = 0, highlights: Double = 0, shadows: Double = 0) {
        self.exposure = exposure
        self.brightness = brightness
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
    }

    /// Missing keys (older or newer files) read as 0.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
    }

    public static let zero = LightAdjust()

    /// Nothing to do (every value rounds to 0).
    public var isIdentity: Bool {
        abs(exposure) < 0.005 && abs(brightness) < 0.005 && abs(contrast) < 0.005 && abs(highlights) < 0.005 && abs(shadows) < 0.005
    }

    /// nil for "no change", so a photo whose sliders are all back at 0 has no light edit at all.
    public var nonIdentity: LightAdjust? { isIdentity ? nil : self }

    /// Values clamped to their ranges and rounded to 0.01 (what gets stored).
    public var normalized: LightAdjust {
        func r(_ v: Double, _ lo: Double, _ hi: Double) -> Double { (min(max(v, lo), hi) * 100).rounded() / 100 }
        return LightAdjust(exposure: r(exposure, -2, 2), brightness: r(brightness, -1, 1), contrast: r(contrast, -1, 1),
                           highlights: r(highlights, -1, 1), shadows: r(shadows, -1, 1))
    }

    /// A stable text key (caches, task ids).
    public var key: String { String(format: "%.3f|%.3f|%.3f|%.3f|%.3f", exposure, brightness, contrast, highlights, shadows) }

    // MARK: The five controls (one table for both platforms' sliders)

    public enum Control: String, CaseIterable, Identifiable, Sendable {
        case exposure, brightness, contrast, highlights, shadows
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .exposure: return "Exposure"
            case .brightness: return "Brightness"
            case .contrast: return "Contrast"
            case .highlights: return "Highlights"
            case .shadows: return "Shadows"
            }
        }
        public var range: ClosedRange<Double> { self == .exposure ? -2...2 : -1...1 }
        /// "+0.7 EV" / "+35" / "0".
        public func format(_ v: Double) -> String {
            if self == .exposure {
                if abs(v) < 0.005 { return "0.0" }
                return String(format: "%+.1f", v)
            }
            let n = Int((v * 100).rounded())
            return n == 0 ? "0" : String(format: "%+d", n)
        }
    }

    public subscript(_ c: Control) -> Double {
        get {
            switch c {
            case .exposure: return exposure
            case .brightness: return brightness
            case .contrast: return contrast
            case .highlights: return highlights
            case .shadows: return shadows
            }
        }
        set {
            switch c {
            case .exposure: exposure = newValue
            case .brightness: brightness = newValue
            case .contrast: contrast = newValue
            case .highlights: highlights = newValue
            case .shadows: shadows = newValue
            }
        }
    }

    /// "Exposure +0.7 · Shadows +30" (history labels).
    public var summary: String {
        let parts = Control.allCases.filter { abs(self[$0]) >= 0.005 }.map { $0.title + " " + $0.format(self[$0]) }
        return parts.isEmpty ? "No light change" : parts.joined(separator: " · ")
    }

    // MARK: Rendering

    /// The adjusted image (any size; global tone curves, so a preview and the full-size export look the same).
    /// Exposure is exact in linear light (`CIExposureAdjust`); the other four are one smooth per-channel curve
    /// (`CIColorCurves`, a 4096-entry table over display-encoded 0…2, so values pushed past white by exposure can
    /// still be pulled back by Highlights).
    public func apply(to image: CIImage) -> CIImage {
        guard !isIdentity else { return image }
        let e = image.extent
        var out = image
        if abs(exposure) >= 0.005 {
            out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
        }
        if !toneIsIdentity {
            out = out.applyingFilter("CIColorCurves", parameters: [
                "inputCurvesData": curveData,
                "inputCurvesDomain": CIVector(x: 0, y: Self.curveDomain),
                "inputColorSpace": CGColorSpace(name: CGColorSpace.extendedSRGB)!,
            ])
        }
        return out.cropped(to: e)
    }

    private var toneIsIdentity: Bool {
        abs(brightness) < 0.005 && abs(contrast) < 0.005 && abs(highlights) < 0.005 && abs(shadows) < 0.005
    }

    static let curveDomain = 2.0
    static let curveCount = 4096

    /// The table for `CIColorCurves`: float32 RGB triples (the same curve on each channel).
    var curveData: Data {
        var floats = [Float](repeating: 0, count: Self.curveCount * 3)
        for i in 0..<Self.curveCount {
            let u = Double(i) / Double(Self.curveCount - 1) * Self.curveDomain
            let v = Float(tone(u))
            floats[i * 3] = v; floats[i * 3 + 1] = v; floats[i * 3 + 2] = v
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The tone curve for one display-encoded value (0…2; above 1 = past white after exposure). Result 0…1.
    func tone(_ u: Double) -> Double {
        var lin = Self.toLinear(u)
        // Highlights below 0: a soft shoulder above linear 0.25 (display ≈ 0.54) that also brings back values pushed
        // past white. Strength blends from the straight line to the full shoulder.
        if highlights < 0 {
            let knee = 0.25, k = -highlights
            if lin > knee {
                let x = lin - knee
                let shoulder = knee + x / (1 + 2.5 * x)
                lin = lin + (shoulder - lin) * k
            }
        }
        var v = Self.toDisplay(min(max(lin, 0), 1))
        // Shadows: a lift (or drop) centred on the dark quarter, fading out by the mid tones; black stays black.
        if abs(shadows) >= 0.005 {
            let w = v * pow(1 - v, 3) / 0.10546875               // peak 1 at v = 0.25
            v += (shadows > 0 ? 0.13 : 0.08) * shadows * w
        }
        // Highlights above 0: lift the bright quarter, white stays white.
        if highlights >= 0.005 {
            let w = pow(v, 3) * (1 - v) / 0.10546875             // peak 1 at v = 0.75
            v += 0.08 * highlights * w
        }
        v = min(max(v, 0), 1)
        // Brightness: a midtone gamma (+1 → power 0.6, −1 → power 1.6).
        if abs(brightness) >= 0.005 {
            v = pow(v, brightness > 0 ? 1 - 0.4 * brightness : 1 - 0.6 * brightness)
        }
        // Contrast: an S-curve around middle grey (quarter tones move by up to 0.1; less going flat, which greys fast).
        if abs(contrast) >= 0.005 {
            v -= (contrast > 0 ? 0.1 : 0.065) * contrast * sin(2 * .pi * v)
        }
        return min(max(v, 0), 1)
    }

    /// Shared GPU context for on-screen renders (Metal where available).
    static let context = CIContext(options: [.cacheIntermediates: false, .name: "LightAdjust"])

    /// `cg` with the adjustment, same size and color space (8-bit). Returns `cg` itself for no change.
    public static func render(_ cg: CGImage, _ a: LightAdjust) -> CGImage {
        guard !a.isIdentity else { return cg }
        let space = (cg.colorSpace?.model == .rgb ? cg.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let input = CIImage(cgImage: cg)
        let output = a.apply(to: input)
        return context.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: space) ?? cg
    }

    // MARK: Auto

    /// A starting point for this photo: lifts a dark photo (exposure to bring the middle tones up, shadows if the
    /// darks are still deep, highlights if that would clip the sky, a little contrast if it's flat) and leaves a
    /// well-exposed one nearly alone. Based on a small luminance histogram of `cg` (any size).
    public static func auto(for cg: CGImage) -> LightAdjust {
        guard let stats = LuminanceStats(cg) else { return .zero }
        var a = LightAdjust()
        // Exposure: a dark photo is lifted so its middle tones reach ~0.45 (display-encoded) or, when the photo is
        // mostly bright sky, so its brightest parts get near white; never so far that they'd blow out. A photo that's
        // overexposed everywhere comes gently down. Anything in between is left alone (most photos).
        let m = max(stats.median, 0.01)
        let evMid = log2(toLinear(0.45) / toLinear(m))
        let evTop = log2(toLinear(0.92) / toLinear(max(stats.p98, 0.01)))
        var ev = 0.0
        if evTop > 0.3, m < 0.42 || evTop > 0.6 {
            ev = min(max(evMid, evTop * 0.75), evTop + 0.3)
        } else if m > 0.78, stats.p05 > 0.35 {
            ev = -min(log2(toLinear(m) / toLinear(0.62)) * 0.6, 0.6)
        }
        ev = min(max(ev, -0.6), 2)
        if abs(ev) < 0.15 { ev = 0 }
        a.exposure = ev
        let gain = pow(2, ev)
        func after(_ v: Double) -> Double { toDisplay(min(toLinear(v) * gain, 1)) }
        // Bright parts the lift would push into white: pull them back.
        let top = toLinear(stats.p99) * gain
        if ev > 0, top > 0.85 { a.highlights = -min(0.2 + (top - 0.85) * 0.4, 0.7) }
        // Deep shadows left after the exposure change: open them up.
        let low = after(stats.p10)
        if low < 0.08 { a.shadows = min((0.08 - low) * 5 + 0.1, 0.5) }
        // Flat photos (fog, haze, a dark scan): a touch of contrast.
        let spread = after(stats.p95) - after(stats.p05)
        if spread < 0.45 { a.contrast = min((0.45 - spread) * 0.8, 0.3) }
        return a.normalized
    }

    static func toLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func toDisplay(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
}

/// Percentiles of display-encoded luminance (Rec. 709 weights) from a ≤128 px sRGB copy.
struct LuminanceStats {
    var median: Double
    var mean: Double
    var p05: Double, p10: Double, p95: Double, p98: Double, p99: Double

    init?(_ cg: CGImage) {
        let s = min(1, 128 / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * s)), h = max(1, Int(Double(cg.height) * s))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hist = [Int](repeating: 0, count: 256)
        var sum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let l = 0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])
            hist[min(255, Int(l.rounded()))] += 1
            sum += l
        }
        let n = w * h
        func pct(_ p: Double) -> Double {
            let goal = Int(Double(n) * p)
            var acc = 0
            for (v, c) in hist.enumerated() { acc += c; if acc > goal { return Double(v) / 255 } }
            return 1
        }
        median = pct(0.5); mean = sum / Double(n) / 255
        p05 = pct(0.05); p10 = pct(0.10); p95 = pct(0.95); p98 = pct(0.98); p99 = pct(0.99)
    }
}
