import SwiftUI

// Canonical geometry and colors for the app icon and every in-app bunny, on all devices.
struct BunnyGlyph: View {
    var lit = true
    var headTilt: Double = 0
    private let ink = Color(red: 0.11, green: 0.11, blue: 0.10)
    private let accent = Color(red: 0.36, green: 0.49, blue: 0.27)
    private let moss = Color(red: 0.27, green: 0.37, blue: 0.21)
    private let sage = Color(red: 0.55, green: 0.58, blue: 0.40)
    private let nodes = [CGPoint(x: 0.22, y: 0.70), CGPoint(x: 0.50, y: 0.26),
                         CGPoint(x: 0.80, y: 0.58), CGPoint(x: 0.56, y: 0.82)]
    private let edges = [(0, 1), (1, 2), (0, 3), (3, 2)]

    private func point(_ index: Int, _ size: CGFloat) -> CGPoint {
        CGPoint(x: nodes[index].x * size, y: nodes[index].y * size)
    }

    private func leaf(at base: CGPoint, length: CGFloat, angle: CGFloat) -> Path {
        let tip = CGPoint(x: base.x + cos(angle) * length, y: base.y + sin(angle) * length)
        let normal = CGPoint(x: -sin(angle) * length * 0.42, y: cos(angle) * length * 0.42)
        let mid = CGPoint(x: (base.x + tip.x) / 2, y: (base.y + tip.y) / 2)
        return Path { path in
            path.move(to: base)
            path.addQuadCurve(to: tip, control: CGPoint(x: mid.x + normal.x, y: mid.y + normal.y))
            path.addQuadCurve(to: base, control: CGPoint(x: mid.x - normal.x, y: mid.y - normal.y))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let s = min(geometry.size.width, geometry.size.height)
            ZStack {
                Path { path in
                    for (a, b) in edges {
                        path.move(to: point(a, s)); path.addLine(to: point(b, s))
                    }
                }.stroke(ink, style: StrokeStyle(lineWidth: s * 0.08, lineCap: .square))
                ForEach([0, 2, 3], id: \.self) { index in
                    Rectangle().fill(ink).frame(width: s * 0.2, height: s * 0.2).position(point(index, s))
                }
                ZStack {
                    let base = point(1, s)
                    // Viewer-left ear is on the far side: its base is hidden by the head.
                    if lit {
                        leaf(at: CGPoint(x: base.x - s * 0.06, y: base.y - s * 0.12),
                             length: s * 0.26, angle: -2.1).fill(moss)
                    }
                    Rectangle().fill(lit ? accent : ink)
                        .frame(width: s * 0.3, height: s * 0.3).position(base)
                    if lit {
                        leaf(at: CGPoint(x: base.x + s * 0.1, y: base.y - s * 0.08),
                             length: s * 0.34, angle: -0.9).fill(sage)
                    }
                }.rotationEffect(.degrees(headTilt), anchor: UnitPoint(x: 0.5, y: 0.41))
            }
            // Keep both ear tips inside the square at every size and during a small head tilt.
            .frame(width: s, height: s).scaleEffect(0.85).offset(y: s * 0.075)
        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }
}
