// Draws the Horizon Leveler app icon (1024×1024 PNG): a black tile, one white horizon line and a level bubble.
// Run: swift scripts/make-icon.swift AppIcon-1024.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: ~824pt rounded square centered on a 1024 canvas.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius: CGFloat = 185
let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(tilePath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

let white = NSColor.white.cgColor
let center = CGPoint(x: size / 2, y: size / 2)
let bubbleRadius: CGFloat = 92
let gap: CGFloat = 34
let lineWidth: CGFloat = 26

// The horizon: one line across, broken where the bubble sits.
ctx.setStrokeColor(white)
ctx.setLineWidth(lineWidth)
ctx.setLineCap(.round)
for (from, to) in [(tile.minX + 120, center.x - bubbleRadius - gap), (center.x + bubbleRadius + gap, tile.maxX - 120)] {
    ctx.move(to: CGPoint(x: from, y: center.y))
    ctx.addLine(to: CGPoint(x: to, y: center.y))
}
ctx.strokePath()

// The level bubble: a ring centered on the horizon.
ctx.setLineWidth(lineWidth)
ctx.strokeEllipse(in: CGRect(x: center.x - bubbleRadius, y: center.y - bubbleRadius, width: bubbleRadius * 2, height: bubbleRadius * 2))

// Subtle edge highlight
ctx.addPath(tilePath)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
ctx.setLineWidth(4)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
