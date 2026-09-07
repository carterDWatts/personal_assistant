// Renders the app icon: the map mark on a dark rounded square, at every size an iconset needs.
// Usage: swift scripts/make_icon.swift build/icon.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// Node positions in a unit square, y up. The second node is the one lit up.
let nodes: [CGPoint] = [CGPoint(x: 0.24, y: 0.34), CGPoint(x: 0.5, y: 0.72), CGPoint(x: 0.78, y: 0.44), CGPoint(x: 0.57, y: 0.22)]
let edges = [(0, 1), (1, 2), (0, 3), (3, 2)]
let background = NSColor(calibratedRed: 0.79, green: 0.78, blue: 0.75, alpha: 1)
let ink = NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.11, alpha: 1)
let accent = NSColor(calibratedRed: 0.33, green: 0.53, blue: 0.26, alpha: 1)
let sage = NSColor(calibratedRed: 0.55, green: 0.65, blue: 0.42, alpha: 1)
let moss = NSColor(calibratedRed: 0.24, green: 0.4, blue: 0.2, alpha: 1)

func render(_ px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let square = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    background.setFill()
    NSBezierPath(rect: square).fill()
    func at(_ p: CGPoint) -> CGPoint { CGPoint(x: square.minX + p.x * square.width, y: square.minY + p.y * square.height) }
    let lines = NSBezierPath()
    lines.lineWidth = square.width * 0.045
    lines.lineCapStyle = .square
    for (a, b) in edges { lines.move(to: at(nodes[a])); lines.line(to: at(nodes[b])) }
    ink.setStroke(); lines.stroke()
    for (i, n) in nodes.enumerated() {
        let r = square.width * (i == 1 ? 0.085 : 0.058)
        let c = at(n)
        let dot = NSBezierPath(rect: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        (i == 1 ? accent : ink).setFill(); dot.fill()
    }
    // The lit joint sprouts two leaves.
    func leafPath(from p: CGPoint, length: CGFloat, angle: CGFloat) -> NSBezierPath {
        let tip = CGPoint(x: p.x + cos(angle) * length, y: p.y + sin(angle) * length)
        let w = length * 0.42, mid = CGPoint(x: (p.x + tip.x) / 2, y: (p.y + tip.y) / 2)
        let n = CGPoint(x: -sin(angle) * w, y: cos(angle) * w)
        let path = NSBezierPath(); path.move(to: p)
        path.curve(to: tip, controlPoint1: CGPoint(x: mid.x + n.x, y: mid.y + n.y), controlPoint2: CGPoint(x: mid.x + n.x, y: mid.y + n.y))
        path.curve(to: p, controlPoint1: CGPoint(x: mid.x - n.x, y: mid.y - n.y), controlPoint2: CGPoint(x: mid.x - n.x, y: mid.y - n.y))
        return path
    }
    let lit = at(nodes[1])
    sage.setFill(); leafPath(from: CGPoint(x: lit.x + square.width * 0.06, y: lit.y + square.width * 0.06), length: square.width * 0.2, angle: 0.9).fill()
    moss.setFill(); leafPath(from: CGPoint(x: lit.x - square.width * 0.04, y: lit.y + square.width * 0.08), length: square.width * 0.15, angle: 2.1).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
             ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
for (name, px) in sizes {
    if let png = render(px) { try? png.write(to: out.appendingPathComponent(name + ".png")) }
}
