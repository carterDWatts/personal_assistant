// Packages the approved artwork at every size required by a macOS iconset.
// Usage: swift scripts/make_icon.swift build/icon.iconset desktop/Assets/AppIcon.png
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = NSImage(contentsOfFile: CommandLine.arguments[2]) else {
    fatalError("Could not load app icon artwork")
}
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        fatalError("Could not allocate icon bitmap")
    }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let size = CGFloat(px)
    let square = NSRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
    NSBezierPath(roundedRect: square, xRadius: size * 0.16, yRadius: size * 0.16).addClip()
    image.draw(in: square, from: .zero, operation: .sourceOver, fraction: 1)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("Could not encode icon") }
    return png
}

let sizes = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
             ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
for (name, px) in sizes {
    try render(px).write(to: out.appendingPathComponent(name + ".png"))
}
