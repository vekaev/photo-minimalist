import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case jpeg, heic, tiff
    public var id: String { rawValue }
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    public var label: String { self == .tiff ? "TIFF 16-bit" : rawValue.uppercased() }
    var utType: UTType { self == .jpeg ? .jpeg : self == .heic ? .heic : .tiff }
}

public enum RenderError: LocalizedError {
    case unreadable(URL), renderFailed(URL), writeFailed(URL)
    public var errorDescription: String? {
        switch self {
        case .unreadable(let u): return "Can't read \(u.lastPathComponent)"
        case .renderFailed(let u): return "Can't render \(u.lastPathComponent)"
        case .writeFailed(let u): return "Can't write \(u.lastPathComponent)"
        }
    }
}

public enum Renderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    public static func loadFullImage(_ url: URL) -> CIImage? {
        if ImageLoader.isRaw(url), let raw = CIRAWFilter(imageURL: url), let image = raw.outputImage {
            return image
        }
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    /// Rotates by `degrees` (counter-clockwise positive) about the center and crops to the largest
    /// rectangle with the original aspect ratio, so no empty corners remain.
    public static func leveled(_ image: CIImage, degrees: Double) -> CIImage {
        let e = image.extent
        let center = CGPoint(x: e.midX, y: e.midY)
        let rotation = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
        let scale = Geometry.cropScale(width: e.width, height: e.height, degrees: degrees)
        let w = floor(e.width * scale), h = floor(e.height * scale)
        let crop = CGRect(x: floor(center.x - w / 2), y: floor(center.y - h / 2), width: w, height: h)
        return image.transformed(by: rotation)
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    public static func export(source: URL, degrees: Double, to destination: URL, format: ExportFormat, quality: Double) throws {
        guard let image = loadFullImage(source) else { throw RenderError.unreadable(source) }
        let output = leveled(image, degrees: degrees)
        let space = CGColorSpace(name: format == .jpeg ? CGColorSpace.sRGB : CGColorSpace.displayP3)!
        guard let cg = context.createCGImage(output, from: output.extent, format: format == .tiff ? .RGBA16 : .RGBA8, colorSpace: space) else {
            throw RenderError.renderFailed(source)
        }
        var properties = metadata(of: source, width: cg.width, height: cg.height)
        if format != .tiff { properties[kCGImageDestinationLossyCompressionQuality] = quality }

        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw RenderError.writeFailed(destination)
        }
        CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.writeFailed(destination) }
    }

    /// EXIF, GPS, IPTC and TIFF metadata from the original, with orientation and pixel size updated.
    private static func metadata(of url: URL, width: Int, height: Int) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let all = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var out: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyExifAuxDictionary] {
            if let value = all[key] { out[key] = value }
        }
        out[kCGImagePropertyOrientation] = 1
        if var tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = out[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            out[kCGImagePropertyExifDictionary] = exif
        }
        return out
    }
}
