// Draws the Photo Minimalist app icon (1024×1024 PNG) in a soft-UI style shared with DayGate and Meeting Memo:
// a warm light tile, a raised camera body, and in its lens a crooked horizon (orange sky, blue sea) with the
// app's dashed level guide running dead straight through it — the one thing the app fixes.
// Run: swift scripts/make-icon.swift AppIcon-1024.png [ios]
//      ios: full-bleed square (the system rounds it); default is the macOS rounded tile with shadow.
import AppKit

let canvas: CGFloat = 1024
let args = CommandLine.arguments.dropFirst()
let out = args.first ?? "AppIcon-1024.png"
let iOS = args.contains("ios")
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }
let paperTop = rgb(242, 241, 237), paperBottom = rgb(232, 230, 225), well = rgb(226, 224, 219), body = rgb(240, 238, 234)
let orange = rgb(243, 108, 36), blue = rgb(43, 102, 224)

// The tile: inset rounded square with a soft shadow on macOS, the whole canvas on iOS.
let tile = iOS ? CGRect(x: 0, y: 0, width: canvas, height: canvas) : CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = iOS ? CGPath(rect: tile, transform: nil) : CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
if !iOS {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0, 0, 0, 0.22))
    ctx.addPath(tilePath); ctx.setFillColor(paperBottom); ctx.fillPath()
    ctx.restoreGState()
}
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let paper = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [paperTop, paperBottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// Soft-UI shadows, scaled to the tile. Light comes from the top left (y grows upward here).
let S = tile.width, c = CGPoint(x: tile.midX, y: tile.midY)
let d = 0.014 * S, blur = 0.03 * S

func rrect(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }
func circle(_ r: CGFloat, _ p: CGPoint) -> CGPath { CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), transform: nil) }

/// A shadow cast inside `shape`, as if it were pressed into the surface.
func innerShadow(_ shape: CGPath, _ offset: CGSize, _ b: CGFloat, _ color: CGColor) {
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let ring = CGMutablePath()
    ring.addRect(tile.insetBy(dx: -S, dy: -S))
    ring.addPath(shape)
    ctx.setShadow(offset: offset, blur: b, color: color)
    ctx.addPath(ring); ctx.setFillColor(rgb(0, 0, 0)); ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

/// Raised off the surface (light top left, dark bottom right), with a soft hollow on top.
func raised(_ shape: CGPath, _ color: CGColor) {
    for (offset, shade) in [(CGSize(width: -d, height: d), rgb(255, 255, 255, 0.95)), (CGSize(width: d, height: -d), rgb(0, 0, 0, 0.28))] {
        ctx.saveGState()
        ctx.setShadow(offset: offset, blur: blur, color: shade)
        ctx.addPath(shape); ctx.setFillColor(color); ctx.fillPath()
        ctx.restoreGState()
    }
    innerShadow(shape, CGSize(width: d * 0.6, height: -d * 0.6), blur * 0.8, rgb(0, 0, 0, 0.25))
    innerShadow(shape, CGSize(width: -d * 0.6, height: d * 0.6), blur * 0.8, rgb(255, 255, 255, 0.5))
}

/// Pressed into the surface.
func pressed(_ shape: CGPath, _ color: CGColor) {
    ctx.addPath(shape); ctx.setFillColor(color); ctx.fillPath()
    innerShadow(shape, CGSize(width: d, height: -d), blur, rgb(0, 0, 0, 0.35))
    innerShadow(shape, CGSize(width: -d * 0.7, height: d * 0.7), blur, rgb(255, 255, 255, 0.8))
}

// Camera: viewfinder bump, body, shutter button.
raised(rrect(CGRect(x: c.x - 0.16 * S, y: c.y + 0.21 * S, width: 0.18 * S, height: 0.08 * S), 0.03 * S), body)
raised(rrect(CGRect(x: c.x - 0.36 * S, y: c.y - 0.25 * S, width: 0.72 * S, height: 0.50 * S), 0.11 * S), body)
raised(rrect(CGRect(x: c.x + 0.20 * S, y: c.y + 0.15 * S, width: 0.09 * S, height: 0.045 * S), 0.022 * S), orange)

// Lens: a well pressed into the body, the glass raised inside it.
let lc = CGPoint(x: c.x, y: c.y - 0.01 * S), r = 0.15 * S
pressed(circle(0.20 * S, lc), well)
let glass = circle(r, lc)
raised(glass, blue)

// Inside the glass: a crooked horizon, and the dashed guide that is level.
ctx.saveGState()
ctx.addPath(glass); ctx.clip()
ctx.saveGState()
ctx.translateBy(x: lc.x, y: lc.y); ctx.rotate(by: 0.16)
ctx.setFillColor(orange); ctx.fill(CGRect(x: -2 * r, y: 0, width: 4 * r, height: 2 * r))
ctx.setFillColor(blue); ctx.fill(CGRect(x: -2 * r, y: -2 * r, width: 4 * r, height: 2 * r))
ctx.restoreGState()
ctx.setStrokeColor(rgb(255, 255, 255, 0.95)); ctx.setLineWidth(0.06 * r)
ctx.setLineDash(phase: 0, lengths: [0.16 * r, 0.11 * r])
ctx.move(to: CGPoint(x: lc.x - r, y: lc.y)); ctx.addLine(to: CGPoint(x: lc.x + r, y: lc.y)); ctx.strokePath()
ctx.restoreGState()
innerShadow(glass, CGSize(width: d * 0.6, height: -d * 0.6), blur * 0.8, rgb(0, 0, 0, 0.25))
innerShadow(glass, CGSize(width: -d * 0.6, height: d * 0.6), blur * 0.8, rgb(255, 255, 255, 0.45))
ctx.restoreGState()

if !iOS {
    // A hairline edge so the light tile reads on a light Dock.
    ctx.addPath(tilePath)
    ctx.setStrokeColor(rgb(0, 0, 0, 0.06))
    ctx.setLineWidth(2)
    ctx.strokePath()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
