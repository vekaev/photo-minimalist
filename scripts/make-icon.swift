// Draws the Photo Minimalist app icon (1024×1024 PNG) on a warm paper tile:
//   lens:   a lens holding a sunset (warm sky over a blue sea), split by a dead-level horizon, with the
//           app's dashed guide line running through it.
//   camera: the same sunset lens set in a soft, rounded camera body.
// Run: swift scripts/make-icon.swift AppIcon-1024.png [ios] [lens|camera] [light]
//      ios: full-bleed square (the system rounds it); default is the macOS rounded tile with shadow.
import AppKit

let size: CGFloat = 1024
let args = CommandLine.arguments.dropFirst()
let out = args.first ?? "AppIcon-1024.png"
let iOS = args.contains("ios")
let style = args.first { ["lens", "camera"].contains($0) } ?? "camera"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: (0..<colors.count).map { CGFloat($0) / CGFloat(colors.count - 1) })!
}
// Dark by default (graphite tile, dark body); pass "light" for the earlier cream version.
let dark = !args.contains("light")
let paper = dark ? rgb(26, 26, 28) : rgb(247, 243, 232)
let paperEdge = dark ? rgb(58, 58, 62) : rgb(230, 224, 208)
let white = dark ? rgb(52, 52, 56) : rgb(255, 255, 255)   // camera body and the rim around the lens
let sky = gradient([rgb(255, 196, 64), rgb(255, 106, 82), rgb(236, 54, 120)])   // amber → coral → magenta, top to horizon
let sea = gradient([rgb(64, 120, 255), rgb(46, 52, 196)])                         // bright blue → indigo, horizon down
let ring = dark ? rgb(96, 128, 255) : rgb(39, 72, 230)

// macOS icon grid: ~824pt rounded square centered on a 1024 canvas.
let inset: CGFloat = iOS ? 0 : 100
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius: CGFloat = iOS ? 0 : 185
let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
if !iOS { ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0, 0, 0, 0.28)) }
ctx.addPath(tilePath); ctx.setFillColor(paper); ctx.fillPath()
ctx.restoreGState()

let k = tile.width / 824
let c = CGPoint(x: size / 2, y: size / 2 - (style == "camera" ? 30 * k : 0))
let r: CGFloat = (style == "camera" ? 190 : 235) * k
let horizon = c.y - r * 0.12
let gap = 16 * k
let lens = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)

// Camera body (camera style): a soft rounded block with a viewfinder hump and a shutter button.
if style == "camera" {
    let body = CGRect(x: c.x - 330 * k, y: c.y - 245 * k, width: 660 * k, height: 470 * k)
    let shape = CGMutablePath()
    shape.addRoundedRect(in: body, cornerWidth: 110 * k, cornerHeight: 110 * k)
    shape.addRoundedRect(in: CGRect(x: c.x - 120 * k, y: body.maxY - 60 * k, width: 240 * k, height: 130 * k), cornerWidth: 50 * k, cornerHeight: 50 * k)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 30 * k, color: rgb(40, 30, 10, 0.18))
    ctx.addPath(shape); ctx.setFillColor(white); ctx.fillPath()
    ctx.restoreGState()
    ctx.setFillColor(rgb(255, 80, 70))
    ctx.addPath(CGPath(roundedRect: CGRect(x: body.maxX - 150 * k, y: body.maxY + 4 * k, width: 80 * k, height: 34 * k), cornerWidth: 17 * k, cornerHeight: 17 * k, transform: nil)); ctx.fillPath()
}

// Arc-style outlines: a thin colored ring, then a thick white rim hugging the lens.
ctx.setStrokeColor(ring); ctx.setLineWidth(10 * k)
ctx.strokeEllipse(in: CGRect(x: c.x - r - 46 * k, y: c.y - r - 46 * k, width: 2 * (r + 46 * k), height: 2 * (r + 46 * k)))
ctx.setFillColor(white)
ctx.fillEllipse(in: CGRect(x: c.x - r - 26 * k, y: c.y - r - 26 * k, width: 2 * (r + 26 * k), height: 2 * (r + 26 * k)))

// The sunset inside the lens: sky above the horizon, sea below, a white level gap between them.
ctx.saveGState()
ctx.addPath(lens); ctx.clip()
ctx.saveGState()
ctx.clip(to: CGRect(x: c.x - r, y: horizon + gap / 2, width: 2 * r, height: 2 * r))
ctx.drawLinearGradient(sky, start: CGPoint(x: c.x, y: c.y + r), end: CGPoint(x: c.x, y: horizon), options: [])
// The sun, half set.
ctx.setFillColor(rgb(255, 238, 200, 0.95))
let sun = r * 0.34
ctx.fillEllipse(in: CGRect(x: c.x - sun, y: horizon - sun + gap / 2, width: 2 * sun, height: 2 * sun))
ctx.restoreGState()
ctx.saveGState()
ctx.clip(to: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: horizon - gap / 2 - (c.y - r)))
ctx.drawLinearGradient(sea, start: CGPoint(x: c.x, y: horizon), end: CGPoint(x: c.x, y: c.y - r), options: [])
ctx.restoreGState()
// Soft glass highlight, top left.
let glass = gradient([rgb(255, 255, 255, 0.35), rgb(255, 255, 255, 0)])
ctx.drawRadialGradient(glass, startCenter: CGPoint(x: c.x - r * 0.45, y: c.y + r * 0.55), startRadius: 0,
                       endCenter: CGPoint(x: c.x - r * 0.45, y: c.y + r * 0.55), endRadius: r * 0.7, options: [])
ctx.restoreGState()

// The app's dashed guide line, dead level, running through the horizon past the lens.
ctx.setStrokeColor(style == "camera" ? rgb(39, 72, 230, 0.55) : ring)
ctx.setLineWidth(12 * k); ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [26 * k, 26 * k])
let reach = style == "camera" ? 0 : 395 * k
for (a, b) in [(c.x - reach, c.x - r - 70 * k), (c.x + r + 70 * k, c.x + reach)] where b > a {
    ctx.move(to: CGPoint(x: a, y: horizon)); ctx.addLine(to: CGPoint(x: b, y: horizon))
}
ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])

// Fine paper grain.
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
var seed: UInt64 = 42
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
for _ in 0..<22000 {
    ctx.setFillColor(rnd() > 0.5 ? rgb(255, 255, 255, 0.05) : rgb(0, 0, 0, 0.03))
    ctx.fill(CGRect(x: tile.minX + rnd() * tile.width, y: tile.minY + rnd() * tile.height, width: 2, height: 2))
}
ctx.restoreGState()

if !iOS { ctx.addPath(tilePath); ctx.setStrokeColor(paperEdge); ctx.setLineWidth(3); ctx.strokePath() }

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
