import Foundation
import ImageIO

/// What the camera wrote about a photo (EXIF) plus its size on disk. Read from the file's header only
/// (`kCGImageSourceShouldCache` off, no decode), so it costs one small read even on a slow memory card.
public struct PhotoInfo: Codable, Equatable, Sendable {
    /// EXIF DateTimeOriginal as wall-clock time, stored as if it were UTC (cameras rarely know their time zone);
    /// always formatted in UTC so it reads the same as on the camera wherever the Mac is.
    public var taken: Date?
    public var make: String?
    public var model: String?
    public var lens: String?
    /// Millimetres, as written (real focal length).
    public var focalLength: Double?
    /// 35 mm equivalent, when the camera writes it.
    public var focalLength35: Int?
    public var aperture: Double?
    /// Seconds.
    public var exposure: Double?
    public var iso: Int?
    /// As stored in the file (before orientation).
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// EXIF orientation 1…8.
    public var orientation: Int?
    /// Bytes of the shown file.
    public var fileSize: Int64?
    /// The RAW twin ("RAF") and its size, when the photo is a RAW + JPEG pair.
    public var rawType: String?
    public var rawSize: Int64?

    public init() {}

    // MARK: Reading

    /// - Parameter companions: files that travel with this one (the RAW twin); only their size is looked up.
    public static func read(url: URL, companions: [URL] = []) -> PhotoInfo? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else { return nil }
        var info = PhotoInfo()
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        info.taken = (exif[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(parseDate)
            ?? (tiff[kCGImagePropertyTIFFDateTime] as? String).flatMap(parseDate)
        info.make = clean(tiff[kCGImagePropertyTIFFMake] as? String)
        info.model = clean(tiff[kCGImagePropertyTIFFModel] as? String)
        info.lens = clean(exif[kCGImagePropertyExifLensModel] as? String) ?? clean(aux[kCGImagePropertyExifAuxLensModel] as? String)
        info.focalLength = number(exif[kCGImagePropertyExifFocalLength])
        info.focalLength35 = number(exif[kCGImagePropertyExifFocalLenIn35mmFilm]).map { Int($0.rounded()) }.flatMap { $0 > 0 ? $0 : nil }
        info.aperture = number(exif[kCGImagePropertyExifFNumber])
        info.exposure = number(exif[kCGImagePropertyExifExposureTime])
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [Any], let first = isos.first.flatMap(number) {
            info.iso = Int(first)
        }
        info.pixelWidth = number(props[kCGImagePropertyPixelWidth]).map { Int($0) }
        info.pixelHeight = number(props[kCGImagePropertyPixelHeight]).map { Int($0) }
        info.orientation = number(props[kCGImagePropertyOrientation]).map { Int($0) }

        info.fileSize = size(of: url)
        if let raw = companions.first {
            info.rawType = raw.pathExtension.uppercased()
            info.rawSize = companions.compactMap(size).reduce(0, +)
        }
        return info
    }

    private static func size(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))), !t.isEmpty else { return nil }
        return t
    }

    private static let exifDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    static func parseDate(_ s: String) -> Date? { exifDate.date(from: String(s.prefix(19))) }

    // MARK: Values for display

    /// Width × height as the photo is seen (orientation applied).
    public var displaySize: (width: Int, height: Int)? {
        guard let w = pixelWidth, let h = pixelHeight else { return nil }
        return (orientation ?? 1) >= 5 ? (h, w) : (w, h)
    }

    public var focalText: String? { focalLength.map { Self.trim($0, digits: 1) + " mm" } }
    public var apertureText: String? { aperture.map { "ƒ/" + Self.trim($0, digits: 1) } }
    /// "1/250 s", "0.5 s", "2 s".
    public var shutterText: String? { shutterValue.map { $0 + " s" } }
    public var isoText: String? { iso.map { "ISO \($0)" } }

    private var shutterValue: String? {
        guard let t = exposure, t > 0 else { return nil }
        if t >= 0.3 { return Self.trim(t, digits: 1) }
        return "1/\(Int((1 / t).rounded()))"
    }

    /// "23 mm · ƒ/2.8 · 1/250 s · ISO 400"
    public var exposureLine: String? {
        let parts = [focalText, apertureText, shutterText, isoText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "23 mm ƒ/2.8 1/250 ISO 400": the same, tighter, for one line under a name.
    public var compactExposure: String? {
        let parts = [focalText, apertureText, shutterValue, isoText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "X100V · 23mm F2" (the lens only when the camera names it).
    public var cameraLine: String? {
        let parts = [model, lens].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "6240 × 4160 · 21.4 MB (+ RAF 83 MB)"
    public var sizeLine: String? {
        var parts: [String] = []
        if let d = displaySize { parts.append("\(d.width) × \(d.height)") }
        if var bytes = fileSize.map(Self.bytes) {
            if let type = rawType, let raw = rawSize { bytes += " (+ \(type) \(Self.bytes(raw)))" }
            parts.append(bytes)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Oct 3, 2026 at 14:22"
    public var dateText: String? { taken.map { $0.formatted(Self.style.year().month(.abbreviated).day().hour().minute()) } }
    /// "Oct 3, 14:22"
    public var shortDateText: String? { taken.map { $0.formatted(Self.style.month(.abbreviated).day().hour().minute()) } }

    /// "Oct 3, 14:22 · 23 mm ƒ/2.8 1/250 ISO 400": the one extra line under a name.
    public var summaryLine: String? {
        let parts = [shortDateText, compactExposure].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Label / value pairs for an info card, in reading order; missing values are left out.
    public var details: [(label: String, value: String)] {
        var rows: [(String, String?)] = [
            ("Taken", dateText),
            ("Camera", [make.flatMap { m in model?.localizedCaseInsensitiveContains(m) == true ? nil : m }, model].compactMap { $0 }.joined(separator: " ").nilIfEmpty),
            ("Lens", lens),
        ]
        var focal = focalText
        if let f35 = focalLength35, let f = focalLength, abs(Double(f35) - f) >= 1 { focal = (focal ?? "") + " (\(f35) mm equiv.)" }
        rows += [
            ("Focal length", focal),
            ("Aperture", apertureText),
            ("Shutter", shutterText),
            ("ISO", iso.map(String.init)),
            ("Pixels", displaySize.map { "\($0.width) × \($0.height)" + Self.megapixels($0.width * $0.height) }),
            ("File size", fileSize.map(Self.bytes)),
            (rawType ?? "RAW", rawSize.map(Self.bytes)),
            ("Orientation", orientation.flatMap(Self.orientationName)),
        ]
        return rows.compactMap { label, value in value.map { (label, $0) } }
    }

    private static let style = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!)

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private static func megapixels(_ pixels: Int) -> String {
        pixels >= 1_000_000 ? " · " + trim(Double(pixels) / 1_000_000, digits: 1) + " MP" : ""
    }

    /// 2.8 → "2.8", 8.0 → "8".
    static func trim(_ v: Double, digits: Int) -> String {
        let s = String(format: "%.\(digits)f", v)
        return s.contains(".") ? String(s.reversed().drop(while: { $0 == "0" }).drop(while: { $0 == "." }).reversed()) : s
    }

    private static func orientationName(_ o: Int) -> String? {
        switch o {
        case 1: return "Normal"
        case 3: return "Rotated 180°"
        case 6: return "Rotated 90° CW"
        case 8: return "Rotated 90° CCW"
        case 2, 4, 5, 7: return "Mirrored (\(o))"
        default: return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
