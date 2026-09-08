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


// Every placement uses the shared glyph; only the head moves while thinking.
struct Mark: View {
    let palette: Palette
    var lit = true
    var thinking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !thinking || reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let tilt = thinking && !reduceMotion ? sin(time * 1.3) * 4 : 0
            BunnyGlyph(lit: lit, headTilt: tilt)
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
