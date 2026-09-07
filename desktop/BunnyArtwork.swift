import SwiftUI

struct Palette {
    let background, surface, bubble, line, ink, muted, accent, moss, sage, deep: Color
    static func forScheme(_ scheme: ColorScheme) -> Palette {
        Palette(background: Color(red: 0.8, green: 0.79, blue: 0.76),
                surface: Color(red: 0.86, green: 0.855, blue: 0.83),
                bubble: Color(red: 0.73, green: 0.72, blue: 0.69),
                line: Color.black.opacity(0.22),
                ink: Color(nsColor: .labelColor),
                muted: Color(nsColor: .secondaryLabelColor),
                accent: Color(red: 0.36, green: 0.49, blue: 0.27),
                moss: Color(red: 0.27, green: 0.37, blue: 0.21),
                sage: Color(red: 0.55, green: 0.58, blue: 0.4),
                deep: Color(red: 0.17, green: 0.25, blue: 0.15))
    }
}


func leaf(at point: CGPoint, length: CGFloat, angle: CGFloat) -> Path {
    var path = Path()
    let tip = CGPoint(x: point.x + cos(angle) * length, y: point.y + sin(angle) * length)
    let width = length * 0.42
    let normal = CGPoint(x: -sin(angle) * width, y: cos(angle) * width)
    let mid = CGPoint(x: (point.x + tip.x) / 2, y: (point.y + tip.y) / 2)
    path.move(to: point)
    path.addQuadCurve(to: tip, control: CGPoint(x: mid.x + normal.x, y: mid.y + normal.y))
    path.addQuadCurve(to: point, control: CGPoint(x: mid.x - normal.x, y: mid.y - normal.y))
    return path
}

// The mark: a scaffold of four joints, one of them grown over.
struct Mark: View {
    let palette: Palette
    var lit = true
    var thinking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let nodes: [CGPoint] = [CGPoint(x: 0.22, y: 0.7), CGPoint(x: 0.5, y: 0.26), CGPoint(x: 0.8, y: 0.58), CGPoint(x: 0.56, y: 0.82)]
    private let edges = [(0, 1), (1, 2), (0, 3), (3, 2)]
    private func at(_ p: CGPoint, _ s: CGFloat) -> CGPoint { CGPoint(x: p.x * s, y: p.y * s) }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !thinking || reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let tilt = thinking && !reduceMotion ? sin(time * 1.3) * 4 : 0
            GeometryReader { geo in
                let s = min(geo.size.width, geo.size.height)
                ZStack {
                    Path { path in
                        for (a, b) in edges { path.move(to: at(nodes[a], s)); path.addLine(to: at(nodes[b], s)) }
                    }.stroke(palette.ink, style: StrokeStyle(lineWidth: s * 0.08, lineCap: .square))
                    ForEach([0, 2, 3], id: \.self) { i in
                        let c = at(nodes[i], s)
                        Rectangle().fill(palette.ink).frame(width: s * 0.2, height: s * 0.2).position(c)
                    }
                    ZStack {
                        Rectangle().fill(lit ? palette.accent : palette.ink)
                            .frame(width: s * 0.3, height: s * 0.3).position(at(nodes[1], s))
                        if lit {
                            let base = at(nodes[1], s)
                            leaf(at: CGPoint(x: base.x + s * 0.1, y: base.y - s * 0.08), length: s * 0.34, angle: -0.9).fill(palette.sage)
                            leaf(at: CGPoint(x: base.x - s * 0.06, y: base.y - s * 0.12), length: s * 0.26, angle: -2.1).fill(palette.moss)
                        }
                    }
                    .rotationEffect(.degrees(tilt), anchor: UnitPoint(x: 0.5, y: 0.41))
                }
            }.aspectRatio(1, contentMode: .fit)
        }.accessibilityHidden(true)
    }
}

// Remove the white backing when compositing the painted layer over the app material.
private let flowerBed: NSImage = {
    guard let image = NSImage(named: "FlowerBed"),
          let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let cutout = bitmap.copy(maskingColorComponents: [245, 255, 245, 255, 245, 255]) else {
        return NSImage(named: "FlowerBed") ?? NSImage()
    }
    return NSImage(cgImage: cutout, size: image.size)
}()

// The flowers stay still while the bunny looks around.
struct CornerGrowth: View {
    let palette: Palette
    var thinking = false
    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack(alignment: .topLeading) {
                Mark(palette: palette, thinking: thinking)
                    .frame(width: size * 0.55, height: size * 0.55)
                    .offset(x: size * 0.22, y: size * 0.237)
                Image(nsImage: flowerBed).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            }.frame(width: size, height: size)
        }.aspectRatio(1, contentMode: .fit)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
