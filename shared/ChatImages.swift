import SwiftUI
import UniformTypeIdentifiers
import ImageIO
#if os(iOS)
import PhotosUI
import UIKit
#else
import AppKit
#endif

struct PendingImage: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
    init(data: Data, name: String) throws {
        guard data.count <= 30_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else { throw ImageError.invalid }
        let out = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw ImageError.invalid }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(target), out.length <= 4_000_000 else { throw ImageError.invalid }
        self.data = out as Data; self.name = String(name.prefix(150))
    }
    var upload: [String: Any] { ["operation": "upload", "id": id.uuidString.lowercased(), "name": name, "mime": "image/jpeg", "data": data.base64EncodedString()] }
}
enum ImageError: LocalizedError {
    case invalid
    var errorDescription: String? { "Choose a smaller image in a supported photo format." }
}

struct ImageAttachmentPicker: View {
    @Binding var images: [PendingImage]
    @Binding var error: String
    #if os(iOS)
    @State private var selection: [PhotosPickerItem] = []
    #else
    @State private var choose = false
    #endif
    var body: some View {
        #if os(iOS)
        PhotosPicker(selection: $selection, maxSelectionCount: max(1, 4-images.count), matching: .images) {
            Image(systemName: "photo.badge.plus")
        }.disabled(images.count >= 4).accessibilityLabel("Attach photos")
        .onChange(of: selection) {
            let items = selection
            Task {
                do {
                    for item in items {
                        if let data = try await item.loadTransferable(type: Data.self), images.count < 4 { images.append(try PendingImage(data: data, name: "Photo.jpg")) }
                    }
                } catch { self.error = error.localizedDescription }
                selection = []
            }
        }
        #else
        Menu {
            Button("Choose images…") { choose = true }
            Button("Paste image") {
                do {
                    guard let image = NSImage(pasteboard: .general), let data = image.tiffRepresentation else { throw ImageError.invalid }
                    images.append(try PendingImage(data: data, name: "Pasted image.jpg"))
                } catch { self.error = error.localizedDescription }
            }
        } label: { Image(systemName: "photo.badge.plus") }.disabled(images.count >= 4)
        .fileImporter(isPresented: $choose, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            do {
                for url in try result.get().prefix(4-images.count) {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    images.append(try PendingImage(data: Data(contentsOf: url), name: url.lastPathComponent))
                }
            } catch { self.error = error.localizedDescription }
        }
        #endif
    }
}

struct PendingImageStrip: View {
    @Binding var images: [PendingImage]
    let error: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(images) { image in
                            VStack(spacing: 4) {
                                #if os(iOS)
                                if let native = UIImage(data: image.data) { Image(uiImage: native).resizable().scaledToFill().frame(width: 64, height: 64).clipped() }
                                #else
                                if let native = NSImage(data: image.data) { Image(nsImage: native).resizable().scaledToFill().frame(width: 64, height: 64).clipped() }
                                #endif
                                Button("Remove", systemImage: "xmark") { images.removeAll { $0.id == image.id } }.font(.caption)
                            }
                        }
                    }
                }
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(.horizontal, 18)
    }
}

struct MessageImages: View {
    let ids: [String]
    let load: (String) async throws -> URL
    var body: some View {
        ForEach(ids, id: \.self) { id in StoredImage(id: id, load: load) }
    }
}
private struct StoredImage: View {
    let id: String
    let load: (String) async throws -> URL
    @State private var url: URL?
    @State private var error = false
    @State private var enlarged = false
    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit().frame(maxWidth: 340, maxHeight: 300).onTapGesture { enlarged = true } }
                    else if phase.error != nil { Button("Reload image") { Task { await refresh() } } }
                    else { ProgressView() }
                }
            } else if error { Button("Reload image") { Task { await refresh() } } }
            else { ProgressView() }
        }
        .task(id: id) { await refresh() }
        .sheet(isPresented: $enlarged) {
            VStack { HStack { Spacer(); Button("Done") { enlarged = false } }; if let url { AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { ProgressView() } } }.padding()
        }
    }
    private func refresh() async { do { url = try await load(id); error = false } catch { self.error = true } }
}
