// Packages the shared app artwork at each macOS icon size.
import SwiftUI

@main struct MakeIcon {
    @MainActor static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        let master = URL(fileURLWithPath: CommandLine.arguments[2])
        let masterRenderer = ImageRenderer(content: BunnyGlyph()
            .frame(width: 1024, height: 1024)
            .background(Color(red: 0.80, green: 0.79, blue: 0.76)))
        masterRenderer.scale = 1
        // iOS requires no alpha channel, even when every rendered pixel is opaque.
        guard let rendered = masterRenderer.cgImage,
              let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            fatalError("Could not render shared app artwork")
        }
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        guard let masterImage = context.makeImage(),
              let masterPNG = NSBitmapImageRep(cgImage: masterImage).representation(using: .png, properties: [:]) else {
            fatalError("Could not render shared app artwork")
        }
        try masterPNG.write(to: master)
        let source = NSImage(cgImage: masterImage, size: NSSize(width: 1024, height: 1024))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let sizes = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
                     ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
        for (name, pixels) in sizes {
            let size = CGFloat(pixels)
            let artwork = Image(nsImage: source)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.8, height: size * 0.8)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.16))
                .padding(size * 0.1)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: artwork)
            renderer.scale = 1
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                fatalError("Could not render icon")
            }
            try png.write(to: out.appendingPathComponent(name + ".png"))
        }
    }
}
