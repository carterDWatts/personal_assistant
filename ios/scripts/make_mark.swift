// Renders the mark once, at the sizes the app needs, so every screen shows the same image.
import SwiftUI

let ink = Color(red: 0.11, green: 0.11, blue: 0.1)
let accent = Color(red: 0.36, green: 0.49, blue: 0.27)
let moss = Color(red: 0.27, green: 0.37, blue: 0.21)
let sage = Color(red: 0.55, green: 0.58, blue: 0.4)

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

// A scaffold of four joints, one of them grown over.
struct Mark: View {
    let s: CGFloat
    private let nodes: [CGPoint] = [CGPoint(x: 0.22, y: 0.7), CGPoint(x: 0.5, y: 0.26), CGPoint(x: 0.8, y: 0.58), CGPoint(x: 0.56, y: 0.82)]
    private let edges = [(0, 1), (1, 2), (0, 3), (3, 2)]
    private func at(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * s, y: p.y * s) }
    var body: some View {
        ZStack {
            Path { path in
                for (a, b) in edges { path.move(to: at(nodes[a])); path.addLine(to: at(nodes[b])) }
            }.stroke(ink, style: StrokeStyle(lineWidth: s * 0.08, lineCap: .square))
            ForEach([0, 2, 3], id: \.self) { i in
                Rectangle().fill(ink).frame(width: s * 0.2, height: s * 0.2).position(at(nodes[i]))
            }
            Rectangle().fill(accent).frame(width: s * 0.3, height: s * 0.3).position(at(nodes[1]))
            let base = at(nodes[1])
            leaf(at: CGPoint(x: base.x + s * 0.1, y: base.y - s * 0.08), length: s * 0.34, angle: -0.9).fill(sage)
            leaf(at: CGPoint(x: base.x - s * 0.06, y: base.y - s * 0.12), length: s * 0.26, angle: -2.1).fill(moss)
        }.frame(width: s, height: s)
    }
}

@main struct MakeMark {
    @MainActor static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        for (name, scale) in [("mark", 1), ("mark@2x", 2), ("mark@3x", 3)] {
            let renderer = ImageRenderer(content: Mark(s: 128))
            renderer.scale = CGFloat(scale)
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("Could not render the mark") }
            try png.write(to: out.appendingPathComponent(name + ".png"))
        }
    }
}
