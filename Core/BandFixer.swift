import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

// Band Fixer: removes the faint dark vertical bands a Leica M6 shutter leaves near the left / right edges of
// some frames. Faithful port of the reference `fix_bands.py` (v3, ~/Documents/shutterspedm6-fix):
//   1. Detect per side: fit the known band shape [1, x, x², −gauss] to every row of a 772-px-wide log-luminance
//      map; only rows whose fit is smooth ("clean") count; median depth vs. a per-side threshold.
//   2. Correct per side: measure the band's real (non-parametric) shape from the clean rows, relative to the
//      clean sky just inside the zone, and lift it back (a 1-D log gain across the width).
//   3. Apply the gain at full resolution in linear light (γ 2.2), optionally tilted.
// Portrait images are analysed rotated 90° CCW (like numpy's rot90) so the long side is horizontal.

// MARK: - Settings

public struct BandFixSettings: Codable, Equatable, Sendable {
    /// Strength per side: 0 = off, 1 = as measured, > 1 = more.
    public var left: Double = 1
    public var right: Double = 1
    /// 1 = match the whole zone to the clean sky inside it; 0 = keep the frame edge's brightness, only fill the dip.
    public var flatten: Double = 1
    /// Zone widths as fractions of the long side.
    public var zoneLeft: Double = 0.25
    public var zoneRight: Double = 0.15
    /// Band lean: shift (fraction of width) from top to bottom.
    public var tilt: Double = 0
    /// Correct even when the detector says "below threshold".
    public var force: Bool = false
    /// Measure only from these rows (fractions of the height, top = 0); nil = all rows.
    public var rowsTop: Double?
    public var rowsBottom: Double?

    public init(left: Double = 1, right: Double = 1, flatten: Double = 1, zoneLeft: Double = 0.25,
                zoneRight: Double = 0.15, tilt: Double = 0, force: Bool = false, rows: ClosedRange<Double>? = nil) {
        self.left = left; self.right = right; self.flatten = flatten
        self.zoneLeft = zoneLeft; self.zoneRight = zoneRight; self.tilt = tilt; self.force = force
        self.rowsTop = rows?.lowerBound; self.rowsBottom = rows?.upperBound
    }

    public static let defaults = BandFixSettings()

    public var rows: ClosedRange<Double>? {
        get {
            guard let t = rowsTop, let b = rowsBottom else { return nil }
            return min(t, b)...max(t, b)
        }
        set { rowsTop = newValue?.lowerBound; rowsBottom = newValue?.upperBound }
    }

    public func strength(_ side: BandSide) -> Double { side == .left ? left : right }

    // Tolerant decoding: missing keys fall back to the defaults, so stored settings survive new fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        left = try c.decodeIfPresent(Double.self, forKey: .left) ?? 1
        right = try c.decodeIfPresent(Double.self, forKey: .right) ?? 1
        flatten = try c.decodeIfPresent(Double.self, forKey: .flatten) ?? 1
        zoneLeft = try c.decodeIfPresent(Double.self, forKey: .zoneLeft) ?? 0.25
        zoneRight = try c.decodeIfPresent(Double.self, forKey: .zoneRight) ?? 0.15
        tilt = try c.decodeIfPresent(Double.self, forKey: .tilt) ?? 0
        force = try c.decodeIfPresent(Bool.self, forKey: .force) ?? false
        rowsTop = try c.decodeIfPresent(Double.self, forKey: .rowsTop)
        rowsBottom = try c.decodeIfPresent(Double.self, forKey: .rowsBottom)
    }
}

public enum BandSide: String, CaseIterable, Codable, Sendable {
    case left, right

    /// Band centre / width as fractions of the long side (measured on 225 scans, 6 rolls).
    public var band: (center: Double, sigma: Double) { self == .left ? (0.099, 0.051) : (0.936, 0.015) }
    /// Below these depths sky gradients can fake a band (decoy-tested).
    public var minDepth: Double { self == .left ? 0.06 : 0.03 }
}

// MARK: - Analysis result

public enum BandStatus: Equatable, Sendable {
    /// Band found (depth ≥ threshold, as a fraction: 0.257 = 25.7 % darker).
    case correcting(depth: Double)
    /// Measured, but weaker than the threshold: left alone unless `force`.
    case belowThreshold(depth: Double)
    /// Too few smooth rows in the zone (busy scene, object in the way): never corrected.
    case noCleanArea

    public var depth: Double? {
        switch self {
        case .correcting(let d), .belowThreshold(let d): return d
        case .noCleanArea: return nil
        }
    }

    /// Same wording as the reference CLI: "25.7%", "2.1% (below threshold)", "no clean area".
    public var report: String {
        switch self {
        case .correcting(let d): return String(format: "%.1f%%", d * 100)
        case .belowThreshold(let d): return String(format: "%.1f%%", d * 100) + " (below threshold)"
        case .noCleanArea: return "no clean area"
        }
    }
}

public struct BandSideAnalysis: Sendable {
    public let side: BandSide
    public let status: BandStatus
    /// Depth in percent (nil when there's no clean area).
    public var depthPercent: Double? { status.depth.map { $0 * 100 } }
    /// The side's zone, as fractions of the (landscape) width.
    public let zone: ClosedRange<Double>
    /// Rows (of the analysis map) used for measuring.
    public let cleanRows: [Bool]
    /// Correction at strength 1 (WORK_W samples, log units); nil when there's no clean area.
    public let correction: [Double]?

    /// Whether this side contributes to the gain with these settings.
    public func isApplied(_ settings: BandFixSettings) -> Bool {
        guard correction != nil, settings.strength(side) > 0 else { return false }
        if case .correcting = status { return true }
        return settings.force
    }
}

public struct BandAnalysis: Sendable {
    public let settings: BandFixSettings
    public let left: BandSideAnalysis
    public let right: BandSideAnalysis
    /// Combined log gain across the (landscape) width, `BandFixer.workWidth` samples. Apply with `BandFixer.apply`.
    public let logGain: [Double]
    /// Brightness profile (log luminance, σ2-smoothed median over the measured rows) before / after, for a chart.
    public let profileBefore: [Double]
    public let profileAfter: [Double]
    /// The image was portrait and analysed rotated (long side horizontal).
    public let portrait: Bool
    /// Analysis map (log luminance, workWidth × mapHeight), kept so setting changes never need the image again.
    let map: LogLumaMap

    public var mapHeight: Int { map.height }
    public func side(_ s: BandSide) -> BandSideAnalysis { s == .left ? left : right }
    /// Same rule as the reference: the image changes only if some gain is above 1e-3.
    public var changesImage: Bool { logGain.contains { abs($0) > 1e-3 } }

    /// Re-plans for new settings without touching the image:
    /// strength / force → only recombines; flatten → rebuilds the correction shapes; zones / rows → re-detects
    /// on the stored map (a few ms). Tilt is used at apply time only.
    public func updated(_ new: BandFixSettings) -> BandAnalysis {
        let s = settings
        if new.zoneLeft != s.zoneLeft || new.zoneRight != s.zoneRight || new.rows != s.rows {
            return BandFixer.plan(map: map, settings: new, portrait: portrait)
        }
        if new.flatten != s.flatten {
            func rebuilt(_ a: BandSideAnalysis) -> BandSideAnalysis {
                guard a.correction != nil else { return a }
                let corr = BandFixer.sideCorrection(map, side: a.side, ok: a.cleanRows, zl: new.zoneLeft,
                                                    zr: new.zoneRight, flatten: new.flatten)
                return BandSideAnalysis(side: a.side, status: a.status, zone: a.zone, cleanRows: a.cleanRows, correction: corr)
            }
            return BandFixer.combine(map: map, left: rebuilt(left), right: rebuilt(right), settings: new, portrait: portrait)
        }
        return BandFixer.combine(map: map, left: left, right: right, settings: new, portrait: portrait)
    }
}

/// Log luminance at the analysis size, row-major.
struct LogLumaMap: Sendable {
    let width: Int
    let height: Int
    let values: [Double]
}

// MARK: - Engine

public enum BandFixer {
    public static let workWidth = 772

    public enum FixError: LocalizedError {
        case unreadable(URL)
        public var errorDescription: String? {
            if case .unreadable(let u) = self { return "Can't read \(u.lastPathComponent)" }
            return nil
        }
    }

    // MARK: Public API

    /// Detects and plans the correction for an (already upright) image. Any size works; internally the image is
    /// reduced to a 772-px-wide log-luminance map with Pillow's bilinear (triangle) filter, like the reference.
    public static func analyze(cgImage: CGImage, settings: BandFixSettings = .defaults) -> BandAnalysis {
        let pixels = PixelBuffer(cgImage)
        return plan(map: logLuma(pixels), settings: settings, portrait: pixels.height > pixels.width)
    }

    /// Applies a log gain (`workWidth` samples across the landscape width) to the full image in linear light.
    /// `portrait` nil = decide from the image (height > width), matching `analyze`.
    public static func apply(gain: [Double], to cgImage: CGImage, tilt: Double = 0, portrait: Bool? = nil) -> CGImage {
        var pixels = PixelBuffer(cgImage)
        applyInPlace(gain: gain, to: &pixels, tilt: tilt, portrait: portrait ?? (pixels.height > pixels.width))
        return pixels.makeImage() ?? cgImage
    }

    /// Applies an analysis (its gain and its settings' tilt). Returns the input when there is nothing to change.
    public static func apply(_ analysis: BandAnalysis, to cgImage: CGImage) -> CGImage {
        guard analysis.changesImage else { return cgImage }
        return apply(gain: analysis.logGain, to: cgImage, tilt: analysis.settings.tilt, portrait: analysis.portrait)
    }

    /// Loads (EXIF orientation applied), analyses and fixes a file. The image is unchanged when nothing is applied.
    public static func fix(url: URL, settings: BandFixSettings = .defaults) throws -> (CGImage, BandAnalysis) {
        guard let image = loadOriented(url) else { throw FixError.unreadable(url) }
        var pixels = PixelBuffer(image)
        let portrait = pixels.height > pixels.width
        let analysis = plan(map: logLuma(pixels), settings: settings, portrait: portrait)
        guard analysis.changesImage else { return (image, analysis) }
        applyInPlace(gain: analysis.logGain, to: &pixels, tilt: settings.tilt, portrait: portrait)
        return (pixels.makeImage() ?? image, analysis)
    }

    /// Full-size decode with the EXIF orientation applied.
    public static func loadOriented(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (props?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        guard raw != 1, let orientation = CGImagePropertyOrientation(rawValue: raw) else { return image }
        let ci = CIImage(cgImage: image).oriented(orientation)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let deep = image.bitsPerComponent > 8
        return CIContext(options: [.cacheIntermediates: false])
            .createCGImage(ci, from: ci.extent, format: deep ? .RGBA16 : .RGBA8, colorSpace: space)
    }

    // MARK: Planning (fix_bands.plan)

    static func plan(map: LogLumaMap, settings: BandFixSettings, portrait: Bool) -> BandAnalysis {
        let rows = settings.rows.map { ($0.lowerBound, $0.upperBound) }
        func side(_ s: BandSide) -> BandSideAnalysis {
            let zone = zoneOf(s, settings.zoneLeft, settings.zoneRight)
            guard let d = detect(map, side: s, zl: settings.zoneLeft, zr: settings.zoneRight, rows: rows) else {
                return BandSideAnalysis(side: s, status: .noCleanArea, zone: zone.0...zone.1,
                                        cleanRows: [Bool](repeating: false, count: map.height), correction: nil)
            }
            let status: BandStatus = d.depth >= s.minDepth ? .correcting(depth: d.depth) : .belowThreshold(depth: d.depth)
            let corr = sideCorrection(map, side: s, ok: d.ok, zl: settings.zoneLeft, zr: settings.zoneRight, flatten: settings.flatten)
            return BandSideAnalysis(side: s, status: status, zone: zone.0...zone.1, cleanRows: d.ok, correction: corr)
        }
        return combine(map: map, left: side(.left), right: side(.right), settings: settings, portrait: portrait)
    }

    static func combine(map: LogLumaMap, left: BandSideAnalysis, right: BandSideAnalysis,
                        settings: BandFixSettings, portrait: Bool) -> BandAnalysis {
        let W = map.width
        var total = [Double](repeating: 0, count: W)
        for a in [left, right] where a.isApplied(settings) {
            let s = settings.strength(a.side)
            for (x, c) in a.correction!.enumerated() { total[x] += s * c }
        }
        // Chart rows: the union of both sides' clean rows; with none, the selected (or all) rows. As band_fixer.html.
        let H = map.height
        let anyMeasured = left.correction != nil || right.correction != nil
        var chartRows: [Int] = []
        for y in 0..<H {
            if anyMeasured {
                if left.cleanRows[y] || right.cleanRows[y] { chartRows.append(y) }
            } else if let r = settings.rows {
                if Double(y) >= r.lowerBound * Double(H) && Double(y) < r.upperBound * Double(H) { chartRows.append(y) }
            } else { chartRows.append(y) }
        }
        var before = [Double](repeating: 0, count: W)
        if !chartRows.isEmpty {
            var col = [Double](repeating: 0, count: chartRows.count)
            map.values.withUnsafeBufferPointer { L in
                for x in 0..<W {
                    for (i, y) in chartRows.enumerated() { col[i] = L[y * W + x] }
                    before[x] = median(&col)
                }
            }
            before = gaussian(before, sigma: 2)
        }
        let after = zip(before, total).map { $0 + $1 }
        return BandAnalysis(settings: settings, left: left, right: right, logGain: total,
                            profileBefore: before, profileAfter: after, portrait: portrait, map: map)
    }

    static func zoneOf(_ side: BandSide, _ zl: Double, _ zr: Double) -> (Double, Double) {
        side == .left ? (0.0, zl) : (1.0 - zr, 1.0)
    }

    // MARK: Detection (fix_bands.analyse_side)

    struct Detected { let depth: Double; let ok: [Bool] }

    static func detect(_ map: LogLumaMap, side: BandSide, zl: Double, zr: Double,
                       rows: (Double, Double)?, minRows: Int = 12) -> Detected? {
        let W = map.width, H = map.height
        let (lo, hi) = zoneOf(side, zl, zr)
        let cols = (0..<W).filter { let x = Double($0) / Double(W); return x >= lo && x <= hi }
        let n = cols.count
        guard n >= 4, H > 0 else { return nil }
        let (mu, sig) = side.band
        // Design matrix A (n × 4), column-major.
        var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: 4)
        for (k, c) in cols.enumerated() {
            let x = Double(c) / Double(W)
            A[0][k] = 1; A[1][k] = x; A[2][k] = x * x
            A[3][k] = -exp(-0.5 * ((x - mu) / sig) * ((x - mu) / sig))
        }
        let P = pseudoInverse(A, n: n)                       // 4 × n, so coef = P · z
        var depth = [Double](repeating: 0, count: H), resid = [Double](repeating: 0, count: H)
        let c0 = cols[0]                                      // zone columns are contiguous
        map.values.withUnsafeBufferPointer { L in
            for y in 0..<H {
                let z = L.baseAddress! + y * W + c0
                var coef = (0.0, 0.0, 0.0, 0.0)
                for k in 0..<n {
                    let v = z[k]
                    coef.0 += P[0][k] * v; coef.1 += P[1][k] * v; coef.2 += P[2][k] * v; coef.3 += P[3][k] * v
                }
                var e = 0.0
                for k in 0..<n {
                    let fit = A[0][k] * coef.0 + A[1][k] * coef.1 + A[2][k] * coef.2 + A[3][k] * coef.3
                    let d = fit - z[k]
                    e += d * d
                }
                depth[y] = coef.3
                resid[y] = (e / Double(n)).squareRoot()
            }
        }
        var allowed = [Bool](repeating: true, count: H)
        if let r = rows {
            allowed = [Bool](repeating: false, count: H)
            let a = max(0, Int(r.0 * Double(H))), b = min(H, Int(r.1 * Double(H)))
            if a < b { for y in a..<b { allowed[y] = true } }
        }
        let allowedResid = (0..<H).filter { allowed[$0] }.map { resid[$0] }
        guard !allowedResid.isEmpty else { return nil }
        let floor = percentile(allowedResid, 10)
        var ok = [Bool](repeating: false, count: H)
        var picked: [Double] = []
        for y in 0..<H where allowed[y] && resid[y] < 1.5 * floor && resid[y] < 0.05 {
            ok[y] = true; picked.append(depth[y])
        }
        guard picked.count >= minRows else { return nil }
        return Detected(depth: median(&picked), ok: ok)
    }

    /// (AᵀA)⁻¹Aᵀ via QR (classical Gram-Schmidt, applied twice for stability). `A` is 4 columns of length n.
    static func pseudoInverse(_ A: [[Double]], n: Int) -> [[Double]] {
        var Q = A
        var R = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        for j in 0..<4 {
            for _ in 0..<2 {
                for i in 0..<j {
                    var dot = 0.0
                    for k in 0..<n { dot += Q[i][k] * Q[j][k] }
                    R[i][j] += dot
                    for k in 0..<n { Q[j][k] -= dot * Q[i][k] }
                }
            }
            var norm = 0.0
            for k in 0..<n { norm += Q[j][k] * Q[j][k] }
            norm = norm.squareRoot()
            R[j][j] = norm
            if norm > 0 { for k in 0..<n { Q[j][k] /= norm } }
        }
        // R⁻¹ (upper triangular)
        var Ri = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        for j in 0..<4 {
            Ri[j][j] = R[j][j] != 0 ? 1 / R[j][j] : 0
            for i in stride(from: j - 1, through: 0, by: -1) {
                var s = 0.0
                for k in (i + 1)...j { s += R[i][k] * Ri[k][j] }
                Ri[i][j] = R[i][i] != 0 ? -s / R[i][i] : 0
            }
        }
        var P = [[Double]](repeating: [Double](repeating: 0, count: n), count: 4)
        for i in 0..<4 {
            for k in 0..<n {
                var s = 0.0
                for j in i..<4 { s += Ri[i][j] * Q[j][k] }
                P[i][k] = s
            }
        }
        return P
    }

    // MARK: Correction shape (fix_bands.side_correction)

    static func sideCorrection(_ map: LogLumaMap, side: BandSide, ok: [Bool], zl: Double, zr: Double, flatten: Double) -> [Double] {
        let W = map.width, H = map.height
        let (lo, hi) = zoneOf(side, zl, zr)
        let xs = (0..<W).map { Double($0) / Double(W) }
        let ref = (0..<W).filter {
            let x = xs[$0]
            return side == .left ? (x >= hi && x < hi + 0.06) : (x > lo - 0.06 && x <= lo)
        }
        let rowsOk = (0..<H).filter { ok[$0] }
        var prof0 = [Double](repeating: 0, count: W)
        map.values.withUnsafeBufferPointer { L in
            let refMean = rowsOk.map { y -> Double in
                guard !ref.isEmpty else { return 0 }
                var s = 0.0
                for x in ref { s += L[y * W + x] }
                return s / Double(ref.count)
            }
            var col = [Double](repeating: 0, count: rowsOk.count)
            for x in 0..<W {
                for (i, y) in rowsOk.enumerated() { col[i] = L[y * W + x] - refMean[i] }
                prof0[x] = median(&col)
            }
        }
        let prof = gaussian(prof0, sigma: 3)
        let zone = (0..<W).filter { xs[$0] >= lo && xs[$0] <= hi }
        let m = zone.count
        guard m > 0 else { return [Double](repeating: 0, count: W) }
        let nEdge = min(8, m)
        let edge = side == .left
            ? zone.prefix(nEdge).reduce(0) { $0 + prof[$1] } / Double(nEdge)
            : zone.suffix(nEdge).reduce(0) { $0 + prof[$1] } / Double(nEdge)
        let bridge = side == .left ? linspace(edge, 0, m) : linspace(0, edge, m)
        var corr = [Double](repeating: 0, count: W)
        for (i, x) in zone.enumerated() {
            corr[x] = (1 - flatten) * bridge[i] - prof[x]
        }
        for x in 0..<W {
            let fade = side == .left ? (hi - xs[x]) / 0.03 : (xs[x] - lo) / 0.03
            corr[x] *= min(1, max(0, fade))                   // corr is already 0 outside the zone
        }
        return gaussian(corr, sigma: 2).map { min(0.5, max(-0.5, $0)) }
    }

    // MARK: Log luminance map (fix_bands.log_luma)

    static func logLuma(_ px: PixelBuffer) -> LogLumaMap {
        // Linear mean of R, G, B (γ 2.2), rotated so the long side is horizontal (numpy rot90 for portraits).
        let portrait = px.height > px.width
        let w = portrait ? px.height : px.width, h = portrait ? px.width : px.height
        var lin = [Float](repeating: 0, count: w * h)
        let maxValue = px.bits16 ? 65535 : 255
        let lut = (0...maxValue).map { pow(Double($0) / Double(maxValue), 2.2) }
        lut.withUnsafeBufferPointer { lut in
            lin.withUnsafeMutableBufferPointer { out in
                px.forEachPixelRGB { x, y, r, g, b in
                    let v = Float((lut[r] + lut[g] + lut[b]) / 3)
                    if portrait { out[(px.width - 1 - x) * w + y] = v } else { out[y * w + x] = v }
                }
            }
        }
        let outW = workWidth, outH = max(64, Int(Double(h) * Double(workWidth) / Double(w)))
        let small = pillowBilinear(lin, w: w, h: h, outW: outW, outH: outH)
        var L = small.map { log(Double($0) + 1e-3) }
        L = gaussianAxis0(L, w: outW, h: outH, sigma: 1.5)
        L = gaussianAxis1(L, w: outW, h: outH, sigma: 1.5)
        return LogLumaMap(width: outW, height: outH, values: L)
    }

    /// Pillow's `Image.resize(..., BILINEAR)` for mode "F": separable triangle filter whose support scales with
    /// the reduction factor (antialiased), horizontal pass first, float32 storage between passes.
    static func pillowBilinear(_ src: [Float], w: Int, h: Int, outW: Int, outH: Int) -> [Float] {
        func coeffs(_ inSize: Int, _ outSize: Int) -> (bounds: [(Int, Int)], k: [Double], ksize: Int) {
            let scale = Double(inSize) / Double(outSize)
            let filterscale = max(scale, 1)
            let support = 1.0 * filterscale
            let ksize = Int(support.rounded(.up)) * 2 + 1
            var k = [Double](repeating: 0, count: outSize * ksize)
            var bounds = [(Int, Int)](repeating: (0, 0), count: outSize)
            let ss = 1.0 / filterscale
            for xx in 0..<outSize {
                let center = (Double(xx) + 0.5) * scale
                var xmin = Int(center - support + 0.5); if xmin < 0 { xmin = 0 }
                var xmax = Int(center + support + 0.5); if xmax > inSize { xmax = inSize }
                xmax -= xmin
                var ww = 0.0
                for x in 0..<xmax {
                    var t = abs((Double(x + xmin) - center + 0.5) * ss)
                    t = t < 1 ? 1 - t : 0
                    k[xx * ksize + x] = t; ww += t
                }
                if ww != 0 { for x in 0..<xmax { k[xx * ksize + x] /= ww } }
                bounds[xx] = (xmin, xmax)
            }
            return (bounds, k, ksize)
        }
        let hc = coeffs(w, outW), vc = coeffs(h, outH)
        var tmp = [Float](repeating: 0, count: outW * h)
        src.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { t in
                hc.k.withUnsafeBufferPointer { k in
                    for y in 0..<h {
                        let row = s.baseAddress! + y * w
                        for xx in 0..<outW {
                            let (xmin, n) = hc.bounds[xx]
                            let kk = k.baseAddress! + xx * hc.ksize
                            var acc = 0.0
                            for x in 0..<n { acc += Double(row[xmin + x]) * kk[x] }
                            t[y * outW + xx] = Float(acc)
                        }
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: outW * outH)
        tmp.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                vc.k.withUnsafeBufferPointer { k in
                    var acc = [Double](repeating: 0, count: outW)
                    for yy in 0..<outH {
                        let (ymin, n) = vc.bounds[yy]
                        let kk = k.baseAddress! + yy * vc.ksize
                        for i in 0..<outW { acc[i] = 0 }
                        for y in 0..<n {
                            let row = t.baseAddress! + (ymin + y) * outW
                            let c = kk[y]
                            for xx in 0..<outW { acc[xx] += Double(row[xx]) * c }
                        }
                        for xx in 0..<outW { o[yy * outW + xx] = Float(acc[xx]) }
                    }
                }
            }
        }
        return out
    }

    // MARK: Apply (fix_bands.apply_gain + gamma)

    /// For γ-2.2 data, (v^2.2 · g)^(1/2.2) = v · g^(1/2.2), so the full-res pass is one multiply per sample:
    /// out = round(min(v · g^(1/2.2), max)). Tilt shifts the gain per 16-row strip (landscape rows), as the reference.
    static func applyInPlace(gain: [Double], to px: inout PixelBuffer, tilt: Double, portrait: Bool) {
        guard !gain.isEmpty else { return }
        let landW = portrait ? px.height : px.width, landH = portrait ? px.width : px.height
        let strips = tilt == 0 ? 1 : (landH + 15) / 16
        // multipliers[s][X] for landscape column X in strip s
        var mult = [[Float]](repeating: [], count: strips)
        let n = gain.count
        for s in 0..<strips {
            let shift = tilt == 0 ? 0 : tilt * (Double(s * 16 + 8) / Double(landH) - 0.5)
            mult[s] = (0..<landW).map { X in
                let lg = interp(Double(X) / Double(landW) - shift, gain, n)
                return Float(pow(exp(lg), 1 / 2.2))
            }
        }
        let maxValue: Float = px.bits16 ? 65535 : 255
        let channels = px.channels, colorChannels = px.colorChannels
        let width = px.width, height = px.height
        var rowMult = [Float](repeating: 1, count: width * channels)
        var buf = [Float](repeating: 0, count: width * channels)
        var lo: Float = 0, hi = maxValue
        let count = vDSP_Length(width * channels)
        for y in 0..<height {
            // Per-sample multipliers for this row (alpha / padding channels stay at 1).
            if portrait {
                for x in 0..<width {
                    let m = mult[tilt == 0 ? 0 : (width - 1 - x) / 16][y]
                    for c in 0..<colorChannels { rowMult[x * channels + c] = m }
                }
            } else if y == 0 || strips > 1 {
                let m = mult[strips > 1 ? y / 16 : 0]
                for x in 0..<width { for c in 0..<colorChannels { rowMult[x * channels + c] = m[x] } }
            }
            rowMult.withUnsafeBufferPointer { m in
                buf.withUnsafeMutableBufferPointer { b in
                    let f = b.baseAddress!
                    px.withRow(y) { row in
                        switch row {
                        case .u8(let p):
                            vDSP_vfltu8(p, 1, f, 1, count)
                            vDSP_vmul(f, 1, m.baseAddress!, 1, f, 1, count)
                            vDSP_vclip(f, 1, &lo, &hi, f, 1, count)
                            vDSP_vfixru8(f, 1, p, 1, count)
                        case .u16(let p):
                            vDSP_vfltu16(p, 1, f, 1, count)
                            vDSP_vmul(f, 1, m.baseAddress!, 1, f, 1, count)
                            vDSP_vclip(f, 1, &lo, &hi, f, 1, count)
                            vDSP_vfixru16(f, 1, p, 1, count)
                        }
                    }
                }
            }
        }
    }

    /// numpy.interp(x, arange(n)/n, fp): linear, clamped to the end values.
    static func interp(_ x: Double, _ fp: [Double], _ n: Int) -> Double {
        let p = x * Double(n)
        if p <= 0 { return fp[0] }
        if p >= Double(n - 1) { return fp[n - 1] }
        var i = Int(p)
        if i > n - 2 { i = n - 2 }
        let x0 = Double(i) / Double(n), x1 = Double(i + 1) / Double(n)
        return fp[i] + (fp[i + 1] - fp[i]) / (x1 - x0) * (x - x0)
    }

    // MARK: Numeric helpers (scipy / numpy semantics)

    /// scipy.ndimage.gaussian_filter1d(a, sigma) with mode "reflect" and truncate 4.
    static func gaussian(_ a: [Double], sigma: Double) -> [Double] {
        let n = a.count
        guard n > 0 else { return a }
        let (k, r) = gaussianKernel(sigma)
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var acc = 0.0
            for j in -r...r { acc += a[reflect(i + j, n)] * k[j + r] }
            out[i] = acc
        }
        return out
    }

    static func gaussianKernel(_ sigma: Double) -> ([Double], Int) {
        let r = Int(4 * sigma + 0.5)
        var k = (-r...r).map { exp(-0.5 / (sigma * sigma) * Double($0 * $0)) }
        let s = k.reduce(0, +)
        k = k.map { $0 / s }
        return (k, r)
    }

    /// Mode "reflect" (d c b a | a b c d | d c b a).
    @inline(__always) static func reflect(_ i: Int, _ n: Int) -> Int {
        var i = i
        while i < 0 || i >= n {
            if i < 0 { i = -i - 1 }
            if i >= n { i = 2 * n - i - 1 }
        }
        return i
    }

    /// Blur along axis 0 (down each column) of a row-major w × h map.
    static func gaussianAxis0(_ a: [Double], w: Int, h: Int, sigma: Double) -> [Double] {
        let (k, r) = gaussianKernel(sigma)
        var out = [Double](repeating: 0, count: a.count)
        let idx = (0..<h).map { y in (-r...r).map { reflect(y + $0, h) } }
        a.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<h {
                    let rows = idx[y]
                    for x in 0..<w { o[y * w + x] = 0 }
                    for (j, yy) in rows.enumerated() {
                        let c = k[j], src = s.baseAddress! + yy * w, dst = o.baseAddress! + y * w
                        for x in 0..<w { dst[x] += src[x] * c }
                    }
                }
            }
        }
        return out
    }

    /// Blur along axis 1 (along each row).
    static func gaussianAxis1(_ a: [Double], w: Int, h: Int, sigma: Double) -> [Double] {
        let (k, r) = gaussianKernel(sigma)
        var out = [Double](repeating: 0, count: a.count)
        let idx = (0..<w).map { x in (-r...r).map { reflect(x + $0, w) } }
        a.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<h {
                    let src = s.baseAddress! + y * w
                    for x in 0..<w {
                        var acc = 0.0
                        for (j, xx) in idx[x].enumerated() { acc += src[xx] * k[j] }
                        o[y * w + x] = acc
                    }
                }
            }
        }
        return out
    }

    /// numpy.median (mean of the two middle values for even counts). Sorts `a` in place.
    static func median(_ a: inout [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        a.sort()
        let m = a.count / 2
        return a.count % 2 == 1 ? a[m] : (a[m - 1] + a[m]) / 2
    }

    /// numpy.percentile with linear interpolation.
    static func percentile(_ a: [Double], _ p: Double) -> Double {
        let s = a.sorted()
        let i = Double(s.count - 1) * p / 100
        let lo = Int(i.rounded(.down)), hi = Int(i.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (i - Double(lo))
    }

    /// numpy.linspace(a, b, n).
    static func linspace(_ a: Double, _ b: Double, _ n: Int) -> [Double] {
        guard n > 1 else { return n == 1 ? [a] : [] }
        let step = (b - a) / Double(n - 1)
        var v = (0..<n).map { a + Double($0) * step }
        v[n - 1] = b
        return v
    }
}

// MARK: - Pixels

/// Uncompressed copy of an image in its own color space (no color conversion): 8- or 16-bit, gray or RGBX.
struct PixelBuffer {
    let width: Int
    let height: Int
    let bits16: Bool
    let gray: Bool
    let space: CGColorSpace
    private(set) var bytes: [UInt8]

    var channels: Int { gray ? 1 : 4 }
    var colorChannels: Int { gray ? 1 : 3 }
    var bytesPerRow: Int { width * channels * (bits16 ? 2 : 1) }

    init(_ image: CGImage) {
        width = image.width; height = image.height
        bits16 = image.bitsPerComponent > 8
        let own = image.colorSpace
        gray = own?.model == .monochrome
        if gray {
            space = own!
        } else if let own, own.model == .rgb {
            space = own
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        let bpr = width * (gray ? 1 : 4) * (bits16 ? 2 : 1)
        bytes = [UInt8](repeating: 0, count: bpr * height)
        let info = Self.bitmapInfo(gray: gray, bits16: bits16)
        let (w, h, bits, sp) = (width, height, bits16 ? 16 : 8, space)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: bits,
                                bytesPerRow: bpr, space: sp, bitmapInfo: info)
            ctx?.interpolationQuality = .none
            ctx?.setBlendMode(.copy)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    static func bitmapInfo(gray: Bool, bits16: Bool) -> UInt32 {
        let alpha = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        return alpha | (bits16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
    }

    /// Calls `body(x, y, r, g, b)` with integer sample values (gray repeats the one value).
    func forEachPixelRGB(_ body: (Int, Int, Int, Int, Int) -> Void) {
        bytes.withUnsafeBytes { raw in
            if bits16 {
                let p = raw.bindMemory(to: UInt16.self)
                for y in 0..<height {
                    for x in 0..<width {
                        if gray { let v = Int(p[y * width + x]); body(x, y, v, v, v) }
                        else { let i = (y * width + x) * 4; body(x, y, Int(p[i]), Int(p[i + 1]), Int(p[i + 2])) }
                    }
                }
            } else {
                let p = raw.bindMemory(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        if gray { let v = Int(p[y * width + x]); body(x, y, v, v, v) }
                        else { let i = (y * width + x) * 4; body(x, y, Int(p[i]), Int(p[i + 1]), Int(p[i + 2])) }
                    }
                }
            }
        }
    }

    enum Row { case u8(UnsafeMutablePointer<UInt8>), u16(UnsafeMutablePointer<UInt16>) }

    mutating func withRow(_ y: Int, _ body: (Row) -> Void) {
        let bpr = bytesPerRow, b16 = bits16
        bytes.withUnsafeMutableBytes { raw in
            let start = raw.baseAddress! + y * bpr
            if b16 { body(.u16(start.assumingMemoryBound(to: UInt16.self))) }
            else { body(.u8(start.assumingMemoryBound(to: UInt8.self))) }
        }
    }

    func makeImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: bits16 ? 16 : 8,
                       bitsPerPixel: channels * (bits16 ? 16 : 8), bytesPerRow: bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo(gray: gray, bits16: bits16)),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
