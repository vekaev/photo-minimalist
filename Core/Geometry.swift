import CoreGraphics
import Foundation

/// Angle convention used everywhere: degrees, counter-clockwise positive, as seen on screen.
/// A photo's `correction` is the rotation applied to it; leveling a horizon tilted by `a` needs a correction of `-a`.
public enum Geometry {
    /// Scale of the largest centered rectangle with the image's own aspect ratio that still fits
    /// inside a `width`×`height` image after rotating it by `degrees`.
    public static func cropScale(width: CGFloat, height: CGFloat, degrees: Double) -> CGFloat {
        let t = abs(degrees) * .pi / 180
        let c = CGFloat(cos(t)), s = CGFloat(sin(t))
        let byWidth = width / (width * c + height * s)
        let byHeight = height / (width * s + height * c)
        return min(byWidth, byHeight, 1)
    }

    /// Angle of a line drawn from `p1` to `p2` in view coordinates (y grows down).
    /// Lines closer to vertical are measured against the vertical, so drawing along a building edge makes it upright.
    public static func lineTilt(from p1: CGPoint, to p2: CGPoint) -> Double {
        var deg = atan2(-(p2.y - p1.y), p2.x - p1.x) * 180 / .pi
        if deg > 90 { deg -= 180 } else if deg <= -90 { deg += 180 }
        if deg > 45 { deg -= 90 } else if deg < -45 { deg += 90 }
        return deg
    }

    /// Width / height of the final picture: the image's aspect, narrowed by an optional crop.
    public static func finalAspect(_ imageAspect: CGFloat, crop: CGRect?) -> CGFloat {
        guard let c = crop, c.width > 0, c.height > 0 else { return imageAspect }
        return imageAspect * c.width / c.height
    }

    public static func format(_ degrees: Double) -> String {
        let rounded = (degrees * 10).rounded() / 10
        if rounded == 0 { return "0.0°" }
        return (rounded > 0 ? "+" : "−") + String(format: "%.1f°", abs(rounded))
    }
}
