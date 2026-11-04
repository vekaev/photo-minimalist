// Draws the DMG window's background (640×420 pt): "Drag Photo Minimalist to Applications", an arrow between
// the two icons (placed by scripts/dmg-settings.py on the same grid), and the first-launch hint at the bottom.
// Mid graphite on purpose: Finder draws icon labels black in light mode and white in dark mode, and both
// stay readable on it.
// Run: swift scripts/make-dmg-background.swift out.png 2      (scale 1 or 2)
import AppKit

let args = CommandLine.arguments.dropFirst()
let out = args.first ?? "background.png"
let scale = CGFloat(Double(args.dropFirst().first ?? "1") ?? 1)
let size = CGSize(width: 640, height: 420)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }

// Top-left coordinates like Finder's (y down), converted for Core Graphics.
func y(_ top: CGFloat) -> CGFloat { size.height - top }

let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(112, 112, 117), rgb(88, 88, 93)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: 0), options: [])

func text(_ string: String, top: CGFloat, size points: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: points, weight: weight),
                                                .foregroundColor: NSColor(white: 1, alpha: alpha), .paragraphStyle: style]
    let s = NSAttributedString(string: string, attributes: attrs)
    let h = s.boundingRect(with: CGSize(width: size.width - 60, height: 200), options: [.usesLineFragmentOrigin]).height
    s.draw(with: CGRect(x: 30, y: y(top) - h, width: size.width - 60, height: h), options: [.usesLineFragmentOrigin])
}

text("Drag Photo Minimalist to Applications", top: 44, size: 21, weight: .semibold, alpha: 0.96)
text("Then open it from Applications.", top: 76, size: 13, weight: .regular, alpha: 0.7)

// The arrow between the icons (centres at x 180 and 460, y 205).
ctx.setStrokeColor(rgb(255, 255, 255, 0.75))
ctx.setLineWidth(2.5)
ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 262, y: y(205))); ctx.addLine(to: CGPoint(x: 376, y: y(205))); ctx.strokePath()
ctx.move(to: CGPoint(x: 362, y: y(193))); ctx.addLine(to: CGPoint(x: 377, y: y(205))); ctx.addLine(to: CGPoint(x: 362, y: y(217))); ctx.strokePath()

// A hairline, then the one-time Gatekeeper step (the app isn't notarized).
ctx.setStrokeColor(rgb(255, 255, 255, 0.18)); ctx.setLineWidth(1)
ctx.move(to: CGPoint(x: 60, y: y(330))); ctx.addLine(to: CGPoint(x: 580, y: y(330))); ctx.strokePath()
text("First time only: if your Mac says it can’t check the app, open\nSystem Settings ▸ Privacy & Security and click Open Anyway.", top: 346, size: 12, weight: .regular, alpha: 0.78)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
