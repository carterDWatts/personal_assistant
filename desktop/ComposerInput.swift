import SwiftUI
import AppKit

struct ComposerInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var images: [PendingImage]
    @Binding var error: String
    let placeholder: String
    let ink: Color
    let muted: Color
    let accent: Color

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = AttachmentTextView()
        editor.isRichText = false
        editor.drawsBackground = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 40)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.frame.size.height = 40
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = .zero
        editor.font = .systemFont(ofSize: 16)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        editor.defaultParagraphStyle = paragraph
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Message")
        editor.registerForDraggedTypes([.fileURL, .png, .tiff])
        editor.attach = { [weak coordinator = context.coordinator] board in coordinator?.attach(board) ?? false }
        editor.focusChanged = { [weak coordinator = context.coordinator] value in coordinator?.parent.focused = value }
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? AttachmentTextView else { return }
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        editor.placeholder = placeholder
        editor.placeholderColor = NSColor(muted)
        editor.textColor = NSColor(ink)
        editor.insertionPointColor = NSColor(accent)
        editor.needsDisplay = true
        if focused {
            DispatchQueue.main.async { [weak editor] in
                guard let editor, context.coordinator.parent.focused, editor.window?.firstResponder !== editor else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerInput
        init(_ parent: ComposerInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
        func attach(_ board: NSPasteboard) -> Bool {
            do {
                guard let photos = try ComposerImages.read(board, capacity: 4-parent.images.count) else { return false }
                parent.images.append(contentsOf: photos)
                parent.error = ""
            } catch { parent.error = error.localizedDescription }
            return true // An invalid attachment must not fall back to inserting its path.
        }
    }
}

final class AttachmentTextView: NSTextView {
    var placeholder = ""
    var placeholderColor = NSColor.secondaryLabelColor
    var attach: ((NSPasteboard) -> Bool)?
    var focusChanged: ((Bool) -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: textContainerOrigin, withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 16), .foregroundColor: placeholderColor,
                .paragraphStyle: defaultParagraphStyle ?? NSParagraphStyle.default])
        }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }; return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged?(false) }; return accepted
    }
    override func paste(_ sender: Any?) {
        if attach?(NSPasteboard.general) != true { super.paste(sender) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ComposerImages.containsAttachment(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ComposerImages.containsAttachment(sender.draggingPasteboard) || super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if attach?(sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }
}

enum ComposerImages {
    static func containsAttachment(_ board: NSPasteboard) -> Bool {
        board.availableType(from: [.fileURL, .png, .tiff]) != nil
    }
    static func read(_ board: NSPasteboard, capacity: Int) throws -> [PendingImage]? {
        guard containsAttachment(board) else { return nil }
        guard capacity > 0 else { throw NSError(domain: "Photos", code: 1, userInfo: [NSLocalizedDescriptionKey: "You can attach up to four photos per message."]) }
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            guard urls.count <= capacity else { throw NSError(domain: "Photos", code: 1, userInfo: [NSLocalizedDescriptionKey: "You can attach up to four photos per message."]) }
            return try urls.map { url in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 30_000_000 else { throw ImageError.invalid }
                return try PendingImage(data: Data(contentsOf: url), name: url.lastPathComponent)
            }
        }
        guard let data = NSImage(pasteboard: board)?.tiffRepresentation else { throw ImageError.invalid }
        return [try PendingImage(data: data, name: "Pasted photo.jpg")]
    }
}
