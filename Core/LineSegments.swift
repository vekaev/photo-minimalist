// Line-segment detection and vanishing points for tilt estimation.
//
// Ported from LightCraft (https://github.com/storytold/lightcraft), file `crates/pipeline/src/upright.rs`
// (`detect_segments`, `vanishing_point`, `refine_vp`, `smallest_eigvec`, `vp_error`, `reliable`),
// licensed MIT OR Apache-2.0. Copyright (c) the LightCraft authors. Used here under the MIT license.
//
// Coordinates: like LightCraft, segments are centred and scaled, `(p − centre) / (long edge / 2)`, with y growing
// DOWNWARD (image rows). Callers convert to the app's counter-clockwise-positive convention.

import Foundation

/// A straight line segment in centred coordinates (y down), see the file header.
struct LineSegment: Equatable, Sendable {
    var ax: Double, ay: Double, bx: Double, by: Double

    var length: Double { ((bx - ax) * (bx - ax) + (by - ay) * (by - ay)).squareRoot() }
    var midX: Double { (ax + bx) / 2 }
    var midY: Double { (ay + by) / 2 }

    /// Homogeneous line through the endpoints, normalized so (a, b) is a unit normal.
    var line: SIMD3<Double> {
        let l = cross3(SIMD3(ax, ay, 1), SIMD3(bx, by, 1))
        let n = max((l.x * l.x + l.y * l.y).squareRoot(), 1e-12)
        return l / n
    }

    /// Angle from vertical in degrees (0 = vertical), folded to 0…90.
    var tiltFromVertical: Double { atan2(abs(bx - ax), abs(by - ay)) * 180 / .pi }
}

@inline(__always) func cross3(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

@inline(__always) private func dot3(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }

@inline(__always) private func norm3(_ a: SIMD3<Double>) -> SIMD3<Double> { a / max(dot3(a, a).squareRoot(), 1e-300) }

enum LineSegments {
    // MARK: - Segments

    /// Detects line segments in a luminance plane (row-major, `w × h`, values roughly 0…1, perceptual).
    ///
    /// Pixels with a strong gradient are grown into regions of consistent level-line orientation, seeded from the
    /// strongest gradients; each elongated region is fitted with a segment along its weighted principal axis.
    static func detect(_ lum: [Float], width w: Int, height h: Int) -> [LineSegment] {
        guard w >= 16, h >= 16, lum.count == w * h else { return [] }
        let img = gaussian(lum, w, h, sigma: 0.8)
        let n = w * h
        var mag = [Float](repeating: 0, count: n)
        var ang = [Float](repeating: 0, count: n)   // level-line angle (gradient + 90°), radians, mod π
        img.withUnsafeBufferPointer { p in
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = y * w + x
                    let gx = (p[i - w + 1] + 2 * p[i + 1] + p[i + w + 1]) - (p[i - w - 1] + 2 * p[i - 1] + p[i + w - 1])
                    let gy = (p[i + w - 1] + 2 * p[i + w] + p[i + w + 1]) - (p[i - w - 1] + 2 * p[i - w] + p[i - w + 1])
                    mag[i] = (gx * gx + gy * gy).squareRoot() / 8
                    var a = atan2(gy, gx) + .pi / 2
                    a = a.truncatingRemainder(dividingBy: .pi)
                    if a < 0 { a += .pi }
                    ang[i] = a
                }
            }
        }
        // Adaptive threshold: strong edges relative to the image's own contrast.
        var sorted = mag.filter { $0 > 1e-4 }
        guard sorted.count >= 32 else { return [] }
        sorted.sort()
        let p90 = sorted[sorted.count * 9 / 10]
        let thr = max(p90 * 0.35, 0.008)
        var order = (0..<n).filter { mag[$0] > thr }
        order.sort { mag[$0] > mag[$1] }

        var used = [Bool](repeating: false, count: n)
        let tol = Float(22.5 * Double.pi / 180)
        let minLen = 0.04 * Double(max(w, h))
        let halfLong = Double(max(w, h)) / 2
        let cx = Double(w) / 2, cy = Double(h) / 2
        var out: [LineSegment] = []
        var stack: [Int] = [], region: [Int] = []
        for seed in order where !used[seed] {
            used[seed] = true
            region.removeAll(keepingCapacity: true)
            region.append(seed)
            stack.removeAll(keepingCapacity: true)
            stack.append(seed)
            // Region angle via the doubled-angle mean.
            var sc = cos(2 * ang[seed]), ss = sin(2 * ang[seed])
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                let ra = atan2(ss, sc) / 2
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        if nx < 1 || ny < 1 || nx >= w - 1 || ny >= h - 1 { continue }
                        let j = ny * w + nx
                        if used[j] || mag[j] <= thr { continue }
                        var d = abs(ang[j] - ra).truncatingRemainder(dividingBy: .pi)
                        if d > .pi / 2 { d = .pi - d }
                        if d > tol { continue }
                        used[j] = true
                        region.append(j)
                        stack.append(j)
                        sc += cos(2 * ang[j])
                        ss += sin(2 * ang[j])
                    }
                }
            }
            guard region.count >= 12 else { continue }
            // Weighted principal axis.
            func axis(_ pixels: [Int]) -> (mx: Double, my: Double, ux: Double, uy: Double) {
                var sw = 0.0, mx = 0.0, my = 0.0
                for i in pixels {
                    let wt = Double(mag[i])
                    sw += wt; mx += wt * Double(i % w); my += wt * Double(i / w)
                }
                mx /= sw; my /= sw
                var sxx = 0.0, syy = 0.0, sxy = 0.0
                for i in pixels {
                    let wt = Double(mag[i])
                    let dx = Double(i % w) - mx, dy = Double(i / w) - my
                    sxx += wt * dx * dx; syy += wt * dy * dy; sxy += wt * dx * dy
                }
                let theta = 0.5 * atan2(2 * sxy, sxx - syy)
                return (mx, my, cos(theta), sin(theta))
            }
            var (mx, my, ux, uy) = axis(region)
            var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
            var wlo = Double.greatestFiniteMagnitude, whi = -Double.greatestFiniteMagnitude
            for i in region {
                let dx = Double(i % w) - mx, dy = Double(i / w) - my
                let t = dx * ux + dy * uy, s = -dx * uy + dy * ux
                lo = min(lo, t); hi = max(hi, t); wlo = min(wlo, s); whi = max(whi, s)
            }
            let len = hi - lo, width = max(whi - wlo, 1)
            if len < minLen || len / width < 5 { continue }
            // Addition to the port: sub-pixel refit (see `refine`). Endpoints stay the region's extent.
            if let r = refine(mag, ang, w, h, thr, mx, my, ux, uy, lo, hi) {
                // Re-express the extent around the refined line (project the old endpoints onto it).
                let ax = mx + ux * lo, ay = my + uy * lo, bx = mx + ux * hi, by = my + uy * hi
                (mx, my, ux, uy) = r
                if (bx - ax) * ux + (by - ay) * uy < 0 { ux = -ux; uy = -uy }
                lo = (ax - mx) * ux + (ay - my) * uy
                hi = (bx - mx) * ux + (by - my) * uy
            }
            out.append(LineSegment(ax: (mx + 0.5 + ux * lo - cx) / halfLong, ay: (my + 0.5 + uy * lo - cy) / halfLong,
                                   bx: (mx + 0.5 + ux * hi - cx) / halfLong, by: (my + 0.5 + uy * hi - cy) / halfLong))
        }
        return out
    }

    /// Addition to the port. The principal axis of a grown region is biased when the region leaks into an adjoining
    /// edge (a ridge meeting the horizon) or when a stronger neighbouring region already claimed part of the edge
    /// band: up to ~0.5° on long lines. So the line is refitted from sub-pixel edge positions: every pixel along the
    /// segment, the gradient-magnitude peak across it (±3 px, parabolic interpolation, orientation within 22.5° of the
    /// line), then a magnitude-weighted principal axis of those points, refitted while dropping points more than
    /// 1.5, 1 and 0.7 px off the line. Needs points on at least 30 % of the length.
    private static func refine(_ mag: [Float], _ ang: [Float], _ w: Int, _ h: Int, _ thr: Float,
                               _ mx: Double, _ my: Double, _ ux: Double, _ uy: Double,
                               _ lo: Double, _ hi: Double) -> (Double, Double, Double, Double)? {
        func sample(_ x: Double, _ y: Double) -> Double {
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
            guard x0 >= 0, y0 >= 0, x0 + 1 < w, y0 + 1 < h else { return 0 }
            let fx = x - Double(x0), fy = y - Double(y0), i = y0 * w + x0
            return Double(mag[i]) * (1 - fx) * (1 - fy) + Double(mag[i + 1]) * fx * (1 - fy)
                + Double(mag[i + w]) * (1 - fx) * fy + Double(mag[i + w + 1]) * fx * fy
        }
        let lineAngle = Float(atan2(uy, ux))
        var pts: [(x: Double, y: Double, m: Double)] = []
        var t = lo
        while t <= hi {
            let px = mx + ux * t, py = my + uy * t
            var vals = [Double]()
            for k in -3...3 { vals.append(sample(px - uy * Double(k), py + ux * Double(k))) }
            if let k = vals.indices.max(by: { vals[$0] < vals[$1] }), k > 0, k < 6, vals[k] > Double(thr) {
                let d = vals[k - 1] - 2 * vals[k] + vals[k + 1]
                let off = Double(k - 3) + (d < 0 ? 0.5 * (vals[k - 1] - vals[k + 1]) / d : 0)
                let ex = px - uy * off, ey = py + ux * off
                let ix = Int(ex.rounded()), iy = Int(ey.rounded())
                if ix >= 0, iy >= 0, ix < w, iy < h {
                    var da = abs(ang[iy * w + ix] - lineAngle).truncatingRemainder(dividingBy: .pi)
                    if da > .pi / 2 { da = .pi - da }
                    if da <= Float(22.5 * Double.pi / 180) { pts.append((ex, ey, vals[k])) }
                }
            }
            t += 1
        }
        guard Double(pts.count) >= max(12, 0.3 * (hi - lo)) else { return nil }
        var fit: (Double, Double, Double, Double) = (mx, my, ux, uy)
        for limit in [Double.infinity, 1.5, 1, 0.7] {
            if limit.isFinite {
                let (fx, fy, fux, fuy) = fit
                let kept = pts.filter { abs(-($0.x - fx) * fuy + ($0.y - fy) * fux) <= limit }
                guard kept.count >= 12 else { break }
                pts = kept
            }
            var sw = 0.0, cx = 0.0, cy = 0.0
            for p in pts { sw += p.m; cx += p.m * p.x; cy += p.m * p.y }
            cx /= sw; cy /= sw
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for p in pts {
                let dx = p.x - cx, dy = p.y - cy
                sxx += p.m * dx * dx; syy += p.m * dy * dy; sxy += p.m * dx * dy
            }
            let theta = 0.5 * atan2(2 * sxy, sxx - syy)
            fit = (cx, cy, cos(theta), sin(theta))
        }
        // A refit that turns the line a lot found a different edge: keep the original.
        return abs(fit.2 * ux + fit.3 * uy) > cos(3 * Double.pi / 180) ? fit : nil
    }

    /// Separable Gaussian blur (clamped edges).
    private static func gaussian(_ p: [Float], _ w: Int, _ h: Int, sigma: Float) -> [Float] {
        let r = max(1, Int((3 * sigma).rounded(.up)))
        var k = (-r...r).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let s = k.reduce(0, +); k = k.map { $0 / s }
        var tmp = [Float](repeating: 0, count: p.count), out = tmp
        for y in 0..<h {
            for x in 0..<w {
                var acc: Float = 0
                for t in -r...r { acc += k[t + r] * p[y * w + min(max(x + t, 0), w - 1)] }
                tmp[y * w + x] = acc
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var acc: Float = 0
                for t in -r...r { acc += k[t + r] * tmp[min(max(y + t, 0), h - 1) * w + x] }
                out[y * w + x] = acc
            }
        }
        return out
    }

    // MARK: - Vanishing points

    /// Angular error (radians) between a segment and the direction from its midpoint to the homogeneous point `v`.
    static func vpError(_ s: LineSegment, _ v: SIMD3<Double>) -> Double {
        let dx = v.x - s.midX * v.z, dy = v.y - s.midY * v.z
        let sx = s.bx - s.ax, sy = s.by - s.ay
        let d = (dx * dx + dy * dy).squareRoot()
        if d < 1e-12 { return 0 }
        let c = min(abs((dx * sx + dy * sy) / (d * max((sx * sx + sy * sy).squareRoot(), 1e-12))), 1)
        return acos(c)
    }

    /// Smallest eigenvector of a symmetric 3×3 matrix (Jacobi rotations).
    private static func smallestEigenvector(_ m: [[Double]]) -> SIMD3<Double> {
        var a = m
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<50 {
            var p = 0, q = 1, big = 0.0
            for i in 0..<3 { for j in (i + 1)..<3 where abs(a[i][j]) > big { big = abs(a[i][j]); p = i; q = j } }
            if big < 1e-15 { break }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = theta == 0 ? 1 : (theta > 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot(), s = t * c
            for k in 0..<3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq; a[k][q] = s * akp + c * akq
            }
            for k in 0..<3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk; a[q][k] = s * apk + c * aqk
            }
            for r in 0..<3 {
                let vp = v[r][p], vq = v[r][q]
                v[r][p] = c * vp - s * vq; v[r][q] = s * vp + c * vq
            }
        }
        let i = (0..<3).min { a[$0][$0] < a[$1][$1] } ?? 0
        return norm3(SIMD3(v[0][i], v[1][i], v[2][i]))
    }

    /// Least-squares vanishing point of `segs` (weights = lengths).
    private static func refineVP(_ segs: [LineSegment]) -> SIMD3<Double> {
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        for s in segs {
            let l = s.line, w = s.length
            for i in 0..<3 { for j in 0..<3 { m[i][j] += w * l[i] * l[j] } }
        }
        return smallestEigenvector(m)
    }

    /// The dominant vanishing point of a segment family: RANSAC over pairs (longest segments first, deterministic),
    /// then least squares on the inliers. Returns the point and the total inlier length.
    static func vanishingPoint(_ segs: [LineSegment]) -> (point: SIMD3<Double>, inlierLength: Double)? {
        guard segs.count >= 2 else { return nil }
        let thr = 1.5 * Double.pi / 180
        func score(_ v: SIMD3<Double>) -> Double { segs.reduce(0) { vpError($1, v) < thr ? $0 + $1.length : $0 } }
        let idx = Array(segs.indices.sorted { segs[$0].length > segs[$1].length }.prefix(60))
        let lines = idx.map { segs[$0].line }
        var best: (SIMD3<Double>, Double)?
        for k in 0..<idx.count {
            for m in (k + 1)..<idx.count {
                let v = cross3(lines[k], lines[m])
                if dot3(v, v) < 1e-24 { continue }
                let vn = norm3(v), sc = score(vn)
                if best == nil || sc > best!.1 { best = (vn, sc) }
            }
        }
        guard let (v0, _) = best else { return nil }
        let inl = segs.filter { vpError($0, v0) < thr * 2 }
        guard inl.count >= 2 else { return nil }
        let v = refineVP(inl)
        let fin = segs.filter { vpError($0, v) < thr * 2 }
        guard fin.count >= 2 else { return nil }
        return (v, fin.reduce(0) { $0 + $1.length })
    }

    /// Whether a family's vanishing point is backed by real structure rather than one object (LightCraft `reliable`):
    /// at least three inliers, total inlier length ≥ half the long edge, inliers spread across ≥ a fifth of the long
    /// edge, ≥ 60 % of the family's length agreeing, and the point lying outside the frame (|v| ≥ 2 in centred units).
    static func reliable(_ segs: [LineSegment], _ v: SIMD3<Double>, vertical: Bool) -> Bool {
        let thr = 3 * Double.pi / 180
        let inl = segs.filter { vpError($0, v) < thr }
        let total = inl.reduce(0) { $0 + $1.length }
        let across = inl.map { vertical ? $0.midX : $0.midY }
        let spread = (across.max() ?? 0) - (across.min() ?? 0)
        let family = segs.reduce(0) { $0 + $1.length }
        if abs(v.z) > 1e-9, ((v.x / v.z) * (v.x / v.z) + (v.y / v.z) * (v.y / v.z)).squareRoot() < 2 { return false }
        return inl.count >= 3 && total >= 0.5 && spread >= 0.4 && total >= 0.6 * family
    }
}
