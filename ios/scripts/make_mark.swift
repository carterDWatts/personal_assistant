// Renders shared/BunnyGlyph.swift once, at the sizes the phone needs, so every screen shows the same image.
// Build: swiftc -parse-as-library -framework SwiftUI -framework AppKit shared/BunnyGlyph.swift ios/scripts/make_mark.swift
// Usage: make_mark <Mark.imageset directory>
import SwiftUI

@main struct MakeMark {
    @MainActor static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        for (name, scale) in [("mark", 1), ("mark@2x", 2), ("mark@3x", 3)] {
            let renderer = ImageRenderer(content: BunnyGlyph().frame(width: 128, height: 128))
            renderer.scale = CGFloat(scale)
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("Could not render the mark") }
            try png.write(to: out.appendingPathComponent(name + ".png"))
        }
    }
}
