import AppKit
import SwiftUI

@main struct ComposerInputCheck {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        let file = root.appendingPathComponent("Photo with spaces.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([file as NSURL])
        let photos = try ComposerImages.read(board, capacity: 4)!
        precondition(photos.count == 1 && photos[0].name == file.lastPathComponent && !photos[0].data.isEmpty)
        do { _ = try ComposerImages.read(board, capacity: 0); preconditionFailure("Attachment limit must be enforced") } catch { }
        board.clearContents(); board.setString("A normal pasted sentence", forType: .string)
        let textOnly = try ComposerImages.read(board, capacity: 4)
        precondition(textOnly == nil)
        board.clearContents(); board.setData(bitmap.tiffRepresentation!, forType: .tiff)
        let pasted = try ComposerImages.read(board, capacity: 4)
        precondition(pasted?.count == 1)
        let invalid = root.appendingPathComponent("notes.txt")
        try Data("Not a photo".utf8).write(to: invalid)
        board.clearContents(); board.writeObjects([invalid as NSURL])
        var draft = "Keep my words", images: [PendingImage] = [], error = ""
        let input = ComposerInput(text: Binding(get: { draft }, set: { draft = $0 }), focused: .constant(false),
                                  images: Binding(get: { images }, set: { images = $0 }),
                                  error: Binding(get: { error }, set: { error = $0 }),
                                  placeholder: "Message", ink: .black, muted: .gray, accent: .green)
        let coordinator = input.makeCoordinator()
        precondition(coordinator.attach(board), "Invalid files must be consumed, never inserted as text")
        precondition(!error.isEmpty && images.isEmpty && draft == "Keep my words")
        board.clearContents(); board.writeObjects([file as NSURL])
        precondition(coordinator.attach(board) && images.count == 1 && error.isEmpty && draft == "Keep my words")
        print("Photo drops and pasted images attach previews, preserve text, and enforce the attachment limit.")
    }
}
