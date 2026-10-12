// Tilt from straight line segments.
//
// The segment detector, the consensus rule (`level_angle`) and the vanishing-point checks are ported from
// LightCraft (https://github.com/storytold/lightcraft), file `crates/pipeline/src/upright.rs`,
// licensed MIT OR Apache-2.0. Copyright (c) the LightCraft authors. Used here under the MIT license.
// See `LineSegments.swift` for the detector itself.

import CoreGraphics
import Foundation

/// Estimates a photo's tilt from its straight edges: horizons, but also shelves, window sills, door frames and walls.
/// Works where Vision finds no horizon (interiors, streets) and for small tilts Vision doesn't report (< ~1°).
///
/// How (after LightCraft's Upright "Level", `level_angle` + `reliable`):
/// 1. Line segments are detected on a ~640 px grayscale copy (region growing of consistent edge orientation,
///    then a sub-pixel refit; see `LineSegments`).
/// 2. Segments within 30° of horizontal form the horizontal family, within 30° of vertical the vertical one.
/// 3. Horizontals are preferred (they don't converge when the camera is pitched up or down). Their length-weighted
///    median deviation is the tilt, but only if at least half of the line length within ±10° agrees within 2° of it
///    (consensus), and that agreeing length is at least a quarter of the long edge; otherwise the lines are
///    texture (tree flanks, ridges) and there's no answer. Horizontals that fan out from one nearby vanishing
///    point (a receding wall or platform: lines above eye level slope one way, below it the other) are not used.
/// 4. Otherwise (horizontals unusable, or less than half the vertical length) verticals are used. Pitching the
///    camera makes verticals converge (perspective), which is not tilt, so the vertical family's vanishing point is
///    found first: if it's reliable (LightCraft's `reliable`: backed by ≥ 3 segments spread across the frame, ≥ 60 %
///    of the family's length, lying outside the frame), the camera roll is the direction of that point from the
///    image centre, which is right whether or not the verticals converge. A roll over 3° must also be confirmed by
///    usable horizontals (LightCraft's Auto rule), else it's scene structure and there's no answer. Without a
///    reliable vanishing point the median + consensus rule applies, which rejects converging families by itself.
public enum LineTilt {
    public struct Estimate: Sendable {
        /// Degrees, counter-clockwise positive (same convention as `Detection.angle`).
        public let angle: Double
        /// 0…1: fraction of the line length that agrees with the answer. Always ≥ 0.5 (consensus) when returned.
        public let strength: Double
    }

    static let side = 640           // analysis long edge
    static let consensusDegrees = 2.0
    static let consensusShare = 0.5
    static let window = 10.0          // degrees either side of the axis that take part in the consensus
    static let refineDegrees = 0.5
    static let minAgreeingLength = 0.5   // centred units: a quarter of the long edge
    static let convergenceDistance = 10.0

    public static func estimate(_ image: CGImage) -> Estimate? {
        guard let (gray, w, h) = grayscale(image) else { return nil }
        let lum = gray.map { Float($0) / 255 }   // sRGB-encoded gray is already perceptual
        return estimate(segments: LineSegments.detect(lum, width: w, height: h))
    }

    /// The tilt from already detected segments (centred coordinates, y down).
    static func estimate(segments: [LineSegment]) -> Estimate? {
        let vertical = segments.filter { $0.tiltFromVertical < 30 }
        let horizontal = segments.filter { $0.tiltFromVertical > 60 }
        let lh = horizontal.reduce(0) { $0 + $1.length }, lv = vertical.reduce(0) { $0 + $1.length }
        // Horizontals fanning out from a vanishing point are a receding wall or street, not a level.
        let horizontalsUsable = lh > 0 && !converges(horizontal)
        let levels = horizontalsUsable ? consensus(horizontal, vertical: false) : nil
        if horizontalsUsable && lh >= lv * 0.5 { return levels }
        guard !vertical.isEmpty else { return nil }
        if let (v, _) = LineSegments.vanishingPoint(vertical), LineSegments.reliable(vertical, v, vertical: true) {
            // Direction of the vertical vanishing point (below the centre), in y-down coordinates: atan2(x, y) is
            // the roll, and in y-down a downward direction leaning to +x is the photo turned counter-clockwise.
            let (x, y) = v.y < 0 ? (-v.x, -v.y) : (v.x, v.y)
            let roll = atan2(x, y) * 180 / .pi
            // LightCraft's Auto rule: a roll over 3° must be confirmed by (usable) horizontals, else it's scene
            // structure (the same-side flanks of many trees, a leaning facade).
            let confirmed = abs(roll) <= 3 || levels.map { abs($0.angle - roll) <= 3 } == true
            guard confirmed else { return nil }
            let thr = 3 * Double.pi / 180
            let agree = vertical.filter { LineSegments.vpError($0, v) < thr }.reduce(0) { $0 + $1.length }
            return Estimate(angle: roll, strength: min(1, agree / lv))
        }
        return consensus(vertical, vertical: true)
    }

    /// Whether the horizontals form a perspective fan (a receding wall, platform or street): most of their length
    /// (≥ 50 %, ≥ 3 segments) points at one vanishing point closer than 10 half-widths to the centre, with at least a
    /// quarter of that length on each side of it (lines above eye level slope one way, lines below the other). Such
    /// lines can agree among themselves (all of one wall above eye level) and fake a tilt. Requiring both sides keeps
    /// a long horizon from counting as a "fan" with whatever short line happens to cross it.
    static func converges(_ family: [LineSegment]) -> Bool {
        guard let (v, _) = LineSegments.vanishingPoint(family), abs(v.z) > 1e-9 else { return false }
        let vx = v.x / v.z, vy = v.y / v.z
        guard (vx * vx + vy * vy).squareRoot() < convergenceDistance else { return false }
        let thr = 3 * Double.pi / 180
        let inliers = family.filter { LineSegments.vpError($0, v) < thr }
        let total = family.reduce(0) { $0 + $1.length }
        let inside = inliers.reduce(0) { $0 + $1.length }
        let above = inliers.filter { $0.midY < vy - 0.15 }.reduce(0) { $0 + $1.length }
        let below = inliers.filter { $0.midY > vy + 0.15 }.reduce(0) { $0 + $1.length }
        return inliers.count >= 3 && inside >= 0.5 * total && min(above, below) >= 0.25 * inside
    }

    /// LightCraft's `level_angle` on one family: length-weighted median deviation, accepted only when at least half
    /// of the length agrees within 2°. The answer is then refined to the length-weighted mean of the segments within
    /// 0.5° of the median (sub-pixel segments make that steadier than the median alone).
    static func consensus(_ set: [LineSegment], vertical: Bool) -> Estimate? {
        guard !set.isEmpty else { return nil }
        // Signed deviation from the axis in degrees, in y-down coordinates: positive = clockwise on screen.
        func deviation(_ s: LineSegment) -> Double {
            let dx = s.bx - s.ax, dy = s.by - s.ay
            var a = (vertical ? atan2(dx, dy) : atan2(dy, dx)) * 180 / .pi
            if a > 90 { a -= 180 } else if a < -90 { a += 180 }
            return vertical ? -a : a
        }
        // Addition to the port: only lines within ±10° of the axis take part (the app never suggests more than 8°).
        // Steeper ones in the family (mountain flanks, receding facades) would otherwise outvote a clear horizon.
        let v = set.map { (deviation($0), $0.length) }.filter { abs($0.0) <= window }.sorted { $0.0 < $1.0 }
        let total = v.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        var acc = 0.0
        guard let median = v.first(where: { acc += $0.1; return acc >= total / 2 })?.0 else { return nil }
        let agree = v.filter { abs($0.0 - median) <= consensusDegrees }.reduce(0) { $0 + $1.1 }
        guard agree >= consensusShare * total, agree >= minAgreeingLength else { return nil }
        let near = v.filter { abs($0.0 - median) <= refineDegrees }
        let nearLength = near.reduce(0) { $0 + $1.1 }
        let refined = nearLength > 0 ? near.reduce(0) { $0 + $1.0 * $1.1 } / nearLength : median
        // Clockwise-positive deviation → counter-clockwise-positive tilt.
        return Estimate(angle: -refined, strength: min(1, agree / total))
    }

    private static func grayscale(_ image: CGImage) -> ([UInt8], Int, Int)? {
        let scale = min(1, Double(side) / Double(max(image.width, image.height)))
        let w = max(8, Int(Double(image.width) * scale)), h = max(8, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (pixels, w, h) : nil
    }
}
