// Draws the LaunchGrid app icon: a 3×3 grid of tiles on a gradient squircle.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let inset: CGFloat = 100
let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.current?.restoreGraphicsState()
NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.20, blue: 0.42, alpha: 1),
                    NSColor(srgbRed: 0.36, green: 0.22, blue: 0.62, alpha: 1)])!.draw(in: shape, angle: -60)

let colors: [NSColor] = [
    .systemPink, .systemOrange, .systemYellow,
    .systemGreen, .systemTeal, .systemBlue,
    .systemIndigo, .systemPurple, .white,
]
let tile: CGFloat = 170, gap: CGFloat = 52
let total = tile * 3 + gap * 2
let origin = (size - total) / 2
for i in 0..<9 {
    let c = i % 3, r = 2 - i / 3
    let rect = NSRect(x: origin + CGFloat(c) * (tile + gap), y: origin + CGFloat(r) * (tile + gap), width: tile, height: tile)
    let p = NSBezierPath(roundedRect: rect, xRadius: 44, yRadius: 44)
    let base = colors[i].usingColorSpace(.sRGB)!
    NSGradient(colors: [base.blended(withFraction: 0.25, of: .white)!, base])!.draw(in: p, angle: -90)
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
