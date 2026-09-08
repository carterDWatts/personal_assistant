import SwiftUI
import UIKit

// Concrete as the material, olive for anything alive. The same numbers as the Mac.
struct Palette {
    let background, surface, bubble, line, ink, muted, accent, moss, sage, deep: Color
    static let concrete = Palette(
        background: Color(red: 0.8, green: 0.79, blue: 0.76),
        surface: Color(red: 0.86, green: 0.855, blue: 0.83),
        bubble: Color(red: 0.73, green: 0.72, blue: 0.69),
        line: Color.black.opacity(0.22),
        ink: Color(red: 0.11, green: 0.11, blue: 0.1),
        muted: Color(red: 0.11, green: 0.11, blue: 0.1).opacity(0.55),
        accent: Color(red: 0.36, green: 0.49, blue: 0.27),
        moss: Color(red: 0.27, green: 0.37, blue: 0.21),
        sage: Color(red: 0.55, green: 0.58, blue: 0.4),
        deep: Color(red: 0.17, green: 0.25, blue: 0.15))
}

struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: Int) { state = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

// Concrete grain, generated once and tiled.
private let grainImage: UIImage = {
    let size = 192
    var pixels = [UInt8](repeating: 255, count: size * size * 4)
    var rng = SystemRandomNumberGenerator()
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let v = UInt8.random(in: 0...255, using: &rng)
        pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    return UIImage(cgImage: image)
}()

struct Concrete: View, Equatable {
    let palette: Palette
    static func == (a: Concrete, b: Concrete) -> Bool { true }
    var body: some View {
        ZStack {
            palette.background
            Canvas { context, size in
                var rng = Seeded(31)
                var stains = context
                stains.addFilter(.blur(radius: 30))
                for _ in 0..<30 {
                    let w = CGFloat.random(in: 80...260, using: &rng), h = CGFloat.random(in: 50...180, using: &rng)
                    let x = CGFloat.random(in: -40...size.width, using: &rng), y = CGFloat.random(in: -40...size.height, using: &rng)
                    let dark = Bool.random(using: &rng)
                    stains.fill(Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h)),
                                with: .color((dark ? Color.black : Color.white).opacity(dark ? 0.07 : 0.06)))
                }
            }
            Image(uiImage: grainImage).resizable(resizingMode: .tile).opacity(0.11).blendMode(.overlay)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

// The mark is one image, rendered once by scripts/make_mark.swift, so it is identical everywhere it appears.
struct Mark: View {
    let palette: Palette
    var lit = true
    var thinking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !thinking || reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let tilt = thinking && !reduceMotion ? sin(time * 1.3) * 4 : 0
            Image("Mark").renderingMode(.original).resizable().interpolation(.high).aspectRatio(1, contentMode: .fit)
                .rotationEffect(.degrees(tilt), anchor: UnitPoint(x: 0.5, y: 0.41))
        }.accessibilityHidden(true)
    }
}

// Remove the white backing when compositing the painted layer over the app material.
private let flowerBed: UIImage = {
    guard let image = UIImage(named: "FlowerBed"), let bitmap = image.cgImage,
          let cutout = bitmap.copy(maskingColorComponents: [245, 255, 245, 255, 245, 255]) else {
        return UIImage(named: "FlowerBed") ?? UIImage()
    }
    return UIImage(cgImage: cutout, scale: image.scale, orientation: image.imageOrientation)
}()

// The flowers stay still while the mark looks around.
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
                Image(uiImage: flowerBed).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            }.frame(width: size, height: size)
        }.aspectRatio(1, contentMode: .fit)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

// Square, bordered, no sheen.
struct SquareButton: ButtonStyle {
    let palette: Palette
    var prominent = false
    var size: CGFloat = 44
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(minWidth: size, minHeight: size)
            .foregroundStyle(prominent ? Color.white : palette.ink)
            .background(prominent ? palette.accent : palette.surface)
            .overlay(Rectangle().stroke(palette.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : enabled ? 1 : 0.4)
    }
}
