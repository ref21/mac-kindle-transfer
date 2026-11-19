// Renders the Kindle Drive app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repository root)
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillGradient(_ ctx: CGContext, _ path: CGPath, top: UInt32, bottom: UInt32) {
    let box = path.boundingBox
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient, start: CGPoint(x: box.midX, y: box.maxY),
                           end: CGPoint(x: box.midX, y: box.minY), options: [])
    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext) {
    // Background tile on the standard macOS icon grid (824pt tile inside 1024pt canvas).
    let tile = roundedRect(CGRect(x: 100, y: 100, width: 824, height: 824), 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0x000000, 0.35))
    ctx.addPath(tile)
    ctx.setFillColor(color(0x2B6CA3))
    ctx.fillPath()
    ctx.restoreGState()
    fillGradient(ctx, tile, top: 0x4A9AD4, bottom: 0x1E4F82)

    // E-reader body.
    let bodyRect = CGRect(x: 302, y: 212, width: 420, height: 600)
    let body = roundedRect(bodyRect, 58)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.45))
    ctx.addPath(body)
    ctx.setFillColor(color(0x1C1C1E))
    ctx.fillPath()
    ctx.restoreGState()
    fillGradient(ctx, body, top: 0x34343A, bottom: 0x16161A)

    // Paper screen.
    let screenRect = CGRect(x: bodyRect.minX + 38, y: bodyRect.minY + 78,
                            width: bodyRect.width - 76, height: bodyRect.height - 120)
    let screen = roundedRect(screenRect, 10)
    fillGradient(ctx, screen, top: 0xF7F4EC, bottom: 0xE9E4D6)

    // Lines of text.
    var y = screenRect.maxY - 58
    let left = screenRect.minX + 36
    let full = screenRect.width - 72
    ctx.setFillColor(color(0x3A3A3C))
    ctx.addPath(roundedRect(CGRect(x: left, y: y, width: full * 0.55, height: 22), 11))
    ctx.fillPath()
    y -= 52
    ctx.setFillColor(color(0xA19C90))
    for fraction in [1.0, 0.94, 1.0, 0.88, 0.97, 0.62, 1.0, 0.9] as [CGFloat] {
        ctx.addPath(roundedRect(CGRect(x: left, y: y, width: full * fraction, height: 13), 6.5))
        ctx.fillPath()
        y -= 34
    }

    // Transfer badge: two opposing arrows in an orange disc.
    let center = CGPoint(x: 712, y: 300)
    let radius: CGFloat = 118
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x000000, 0.35))
    ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    let disc = CGPath(ellipseIn: CGRect(x: center.x - radius + 14, y: center.y - radius + 14,
                                        width: (radius - 14) * 2, height: (radius - 14) * 2), transform: nil)
    fillGradient(ctx, disc, top: 0xFFB340, bottom: 0xF07D12)

    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(22)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let gap: CGFloat = 34, span: CGFloat = 56, head: CGFloat = 30
    // Up arrow (left).
    ctx.move(to: CGPoint(x: center.x - gap, y: center.y - span))
    ctx.addLine(to: CGPoint(x: center.x - gap, y: center.y + span))
    ctx.move(to: CGPoint(x: center.x - gap - head, y: center.y + span - head))
    ctx.addLine(to: CGPoint(x: center.x - gap, y: center.y + span))
    ctx.addLine(to: CGPoint(x: center.x - gap + head, y: center.y + span - head))
    // Down arrow (right).
    ctx.move(to: CGPoint(x: center.x + gap, y: center.y + span))
    ctx.addLine(to: CGPoint(x: center.x + gap, y: center.y - span))
    ctx.move(to: CGPoint(x: center.x + gap - head, y: center.y - span + head))
    ctx.addLine(to: CGPoint(x: center.x + gap, y: center.y - span))
    ctx.addLine(to: CGPoint(x: center.x + gap + head, y: center.y - span + head))
    ctx.strokePath()
}

func render(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    drawIcon(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns")
