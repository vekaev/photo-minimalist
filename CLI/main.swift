import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let usage = """
usage:
  leveler-cli analyze <folder>                  print a CSV of detected tilt for every photo
  leveler-cli export <photo> <degrees> <out>    rotate by <degrees> (CCW positive), crop, write JPEG
  leveler-cli make-test <folder>                write synthetic tilted-horizon JPEGs for testing
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

/// Sky over sea with a horizon tilted `degrees` counter-clockwise, plus a vertical post for texture.
func makeScene(width: Int, height: Int, degrees: Double) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let w = CGFloat(width), h = CGFloat(height)
    ctx.translateBy(x: w / 2, y: h / 2)
    ctx.rotate(by: degrees * .pi / 180)
    let big = max(w, h) * 2
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let sky = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.98, green: 0.80, blue: 0.62, alpha: 1), CGColor(red: 0.45, green: 0.62, blue: 0.85, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.saveGState(); ctx.clip(to: CGRect(x: -big, y: 0, width: big * 2, height: big))
    ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: h / 2), options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    let sea = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.20, green: 0.32, blue: 0.42, alpha: 1), CGColor(red: 0.07, green: 0.12, blue: 0.17, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.saveGState(); ctx.clip(to: CGRect(x: -big, y: -big, width: big * 2, height: big))
    ctx.drawLinearGradient(sea, start: .zero, end: CGPoint(x: 0, y: -h / 2), options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    ctx.setFillColor(CGColor(red: 0.12, green: 0.10, blue: 0.09, alpha: 1))
    ctx.fill(CGRect(x: w * 0.15, y: -h * 0.05, width: w * 0.02, height: h * 0.25))
    return ctx.makeImage()!
}

func writeJPEG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fail("can't write \(url.path)") }
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail(usage) }

switch args[1] {
case "analyze":
    let folder = URL(fileURLWithPath: args[2])
    let files = ImageLoader.listImages(in: folder)
    print("file,tilt_deg,correction_deg,confidence")
    let results = UnsafeMutableBufferPointer<Detection?>.allocate(capacity: files.count)
    results.initialize(repeating: nil)
    DispatchQueue.concurrentPerform(iterations: files.count) { i in
        results[i] = HorizonDetector.detect(url: files[i], rawCompanion: nil)
    }
    for (i, url) in files.enumerated() {
        let rel = url.path.replacingOccurrences(of: folder.path + "/", with: "")
        if let d = results[i] {
            print(String(format: "%@,%.2f,%.2f,%.3f", rel, d.angle, d.correction, d.confidence))
        } else {
            print("\(rel),,,")
        }
    }
    results.deallocate()

case "export":
    guard args.count == 5, let degrees = Double(args[3]) else { fail(usage) }
    do {
        try Renderer.export(source: URL(fileURLWithPath: args[2]), degrees: degrees,
                            to: URL(fileURLWithPath: args[4]), format: .jpeg, quality: 0.92)
    } catch { fail(error.localizedDescription) }

case "make-test":
    let folder = URL(fileURLWithPath: args[2])
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for degrees in [-4.0, -2.5, -1.0, 0.0, 1.5, 3.0, 6.0] {
        let name = String(format: "tilt_%+.1f.jpg", degrees)
        writeJPEG(makeScene(width: 3000, height: 2000, degrees: degrees), to: folder.appendingPathComponent(name))
    }

default:
    fail(usage)
}
