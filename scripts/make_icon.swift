// Packages the shared app artwork at each macOS icon size.
import SwiftUI

@main struct MakeIcon {
    @MainActor static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let source = NSImage(contentsOfFile: CommandLine.arguments[2]) else {
            fatalError("Could not load app artwork")
        }
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
