// Draws Macximesed's app icon in the app's own style: paper, ink, a serif M and the small square that marks the
// live watch. No gradients, glows or shadows. Writes Resources/AppIcon.icns (via iconutil).
// Usage: swift scripts/make-icon.swift [out-dir]      (run from the repo root)
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let paper = color(0xF3F1EC)
let ink = color(0x1B1B19)
let line = color(0xB9B4A9)

/// One size, drawn at `px` pixels on Apple's icon grid (the body is 824 of 1024, corner radius 185).
func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let s = CGFloat(px) / 1024
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    paper.setFill()
    shape.fill()
    line.setStroke()
    shape.lineWidth = max(1, 6 * s)
    shape.stroke()

    // The M: New York, heavy, in ink, centred a little above the middle.
    let base = NSFont.systemFont(ofSize: 500 * s, weight: .bold)
    let serif = NSFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: 500 * s) ?? base
    let text = NSAttributedString(string: "M", attributes: [.font: serif, .foregroundColor: ink])
    let size = text.size()
    text.draw(at: NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2 + 40 * s))

    // Underneath: a hairline, as the app's headers have, ending in the small square that marks the live watch.
    ink.setFill()
    let lineY = body.minY + 205 * s
    NSBezierPath(rect: NSRect(x: body.minX + 200 * s, y: lineY, width: 330 * s, height: max(1, 9 * s))).fill()
    let mark = 62 * s
    NSBezierPath(rect: NSRect(x: body.minX + 200 * s + 330 * s + 40 * s, y: lineY + 4.5 * s - mark / 2, width: mark, height: mark)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
    ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
] {
    try draw(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
try draw(1024).write(to: out.appendingPathComponent("AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "Wrote \(out.path)/AppIcon.icns" : "iconutil failed")
