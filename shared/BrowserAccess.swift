import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Human-only controls for the hosted browser. Input uses the private access channel.
struct BrowserAccessView: View {
    let sessionID: String
    let request: (String, [String: Any]) async throws -> [String: Any]
    let completed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picture: Data?
    @State private var location = "Opening browser…"
    @State private var input = ""
    @State private var busy = false
    @State private var error = ""
    private var screenshot: Image? {
        guard let picture else { return nil }
        #if os(iOS)
        guard let image = UIImage(data: picture) else { return nil }; return Image(uiImage: image)
        #else
        guard let image = NSImage(data: picture) else { return nil }; return Image(nsImage: image)
        #endif
    }
    var body: some View {
        ScrollView { VStack(spacing: 12) {
            HStack { Text("Connect a website").font(.headline); Spacer(); Button("Close") { dismiss() } }
            Text(location).font(.caption).textSelection(.enabled).lineLimit(3)
            Text("You control this browser. Tap a field, type below, then press Enter. Done grants access to the website shown above. Passwords and codes stay out of chat.").font(.caption).foregroundStyle(.secondary)
            if let screenshot {
                screenshot.resizable().aspectRatio(4.0/3.0, contentMode: .fit)
                    .overlay { GeometryReader { geometry in
                        Color.clear.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { event in
                            perform(["action":"tap", "x":event.location.x / geometry.size.width * 1024, "y":event.location.y / geometry.size.height * 768])
                        })
                    }}
            } else { ProgressView().frame(height: 180) }
            HStack {
                SecureField("Text for the selected field", text: $input)
                Button("Type") { let text = input; input = ""; perform(["action":"type", "text":text, "replace":true]) }.disabled(input.isEmpty)
            }
            HStack {
                Button("Back") { perform(["action":"back"]) }
                Button("Refresh") { perform(["action":"snapshot"]) }
                Button("↑") { perform(["action":"scroll", "dy":-550]) }
                Button("↓") { perform(["action":"scroll", "dy":550]) }
                Button("Tab") { perform(["action":"press", "text":"Tab"]) }
                Button("Enter") { perform(["action":"press", "text":"Enter"]) }
            }.font(.callout)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Disconnect", role: .destructive) {
                    Task { _ = try? await request("browser_disconnect", ["session_id":sessionID]); dismiss() }
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Done — continue my request") { perform(["action":"finish"]) }.buttonStyle(.borderedProminent)
            }
        }
        .padding() }.disabled(busy)
        .task {
            busy = true
            do {
                let info = try await request("browser_begin", ["session_id":sessionID])
                location = info["origin"] as? String ?? "Website"
                try await act(["action":"snapshot"])
            } catch { self.error = "The browser could not open. Try connecting again." }
            busy = false
        }
    }
    private func perform(_ command: [String: Any]) {
        guard !busy else { return }; busy = true; error = ""
        Task {
            do { try await act(command) }
            catch { self.error = "That action could not finish. Refresh to check the page before trying again." }
            busy = false
        }
    }
    private func act(_ command: [String: Any]) async throws {
        let id = UUID().uuidString.lowercased()
        _ = try await request("browser_command", ["session_id":sessionID, "id":id, "command":command])
        for _ in 0..<120 {
            let response = try await request("browser_result", ["session_id":sessionID, "id":id])
            if response["status"] as? String == "failed" { throw URLError(.cannotLoadFromNetwork) }
            if response["status"] as? String == "done" {
                let result = response["result"] as? [String:Any] ?? [:]
                if result["ready"] as? Bool == true { completed(); dismiss(); return }
                if let data = result["image"] as? String { picture = Data(base64Encoded:data) }
                if let url = result["url"] as? String { location = url }
                return
            }
            try await Task.sleep(nanoseconds:250_000_000)
        }
        throw URLError(.timedOut)
    }
}
