import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

struct MeetingView: View {
    @ObservedObject var library: MeetingLibrary
    @ObservedObject var capture: MeetingCapture
    let runtime: String
    var beforeRecording: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var title = ""
    @State private var kind = "current"
    @State private var expandedTranscript = false
    @State private var showOptions = false
    @FocusState private var naming: Bool
    #if os(iOS)
    @State private var chooseVideo = false
    @State private var video: PhotosPickerItem?
    private var palette: Palette { .concrete }
    #else
    private var palette: Palette { .forScheme(scheme) }
    #endif
    @State private var chooseAudio = false
    @State private var fileError = ""
    private var name: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Conversation \(Date().formatted(date: .abbreviated, time: .shortened))" : title }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if library.selected != nil || capture.active {
                    Mark(palette: palette).frame(width: 24, height: 28)
                }
                Text("Conversations").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("Done")
            }.padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if library.selected == nil && !capture.active {
                        HStack(alignment: .center, spacing: 20) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Let me listen.").font(.system(size: 32, weight: .medium))
                                Text("Bring me a conversation. We can pick up the important parts together.")
                                    .font(.body).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Mark(palette: palette).frame(width: 64, height: 76)
                        }.padding(.bottom, 8)
                    }
                    if !capture.active { importControls }
                    if capture.active {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(capture.recording ? "Recording" : capture.status, systemImage: capture.recording ? "record.circle" : "waveform")
                                    .font(.headline).accessibilityAddTraits(.updatesFrequently)
                                Spacer()
                                if capture.recording {
                                    Button("Stop recording") { Task { await capture.stop(); await library.sync() } }.tint(.red)
                                } else { Button("Pause") { capture.cancelImport() } }
                            }.buttonStyle(MeetingButtonStyle(palette: palette))
                            if !capture.recording { ProgressView(value: capture.progress) }
                            Text("You can close this panel and keep chatting. I’ll save my progress as I go.")
                                .font(.subheadline).foregroundStyle(palette.muted)
                        }.padding(16).background(palette.bubble, in: RoundedRectangle(cornerRadius: 16))
                    }
                    if !fileError.isEmpty { problem(fileError) }
                    if !capture.error.isEmpty && library.selected?.processing?.error != capture.error { problem(capture.error) }
                    if !library.notice.isEmpty { Text(library.notice).font(.subheadline).foregroundStyle(palette.muted) }
                    if library.documents.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(library.documents) { doc in
                                    Button { library.selectedID = doc.id; expandedTranscript = false } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(doc.title).lineLimit(2)
                                            Text(doc.date, style: .date).font(.caption).opacity(0.7)
                                        }.frame(width: 160, alignment: .leading)
                                    }.buttonStyle(MeetingButtonStyle(palette: palette, prominent: library.selectedID == doc.id))
                                        .accessibilityAddTraits(library.selectedID == doc.id ? .isSelected : [])
                                        .disabled(capture.active)
                                }
                            }
                        }.accessibilityLabel("Saved recordings")
                    }
                    if let doc = library.selected { transcript(doc) }
                }.padding(20)
            }.scrollDismissesKeyboard(.interactively)
        }
        .foregroundStyle(palette.ink).tint(palette.accent)
        .background(Concrete(palette: palette).ignoresSafeArea())
        .onChange(of: library.selectedID) { _ in expandedTranscript = false; naming = false }
        #if os(macOS)
        .frame(width: 580, height: 700)
        #else
        .presentationDragIndicator(.visible)
        #endif
        #if os(iOS)
        .photosPicker(isPresented: $chooseVideo, selection: $video, matching: .videos, preferredItemEncoding: .current)
        .onChange(of: video) { _, item in
            guard let item else { return }
            fileError = ""
            capture.importVideo(item, title: name, runtime: runtime, kind: kind)
            video = nil
        }
        #endif
        .fileImporter(isPresented: $chooseAudio, allowedContentTypes: [.audio, .movie, .mpeg4Movie]) { result in
            switch result {
            case .success(let url): fileError = ""; capture.importAudio(url, title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : name, runtime: runtime, kind: kind)
            case .failure(let error): fileError = error.localizedDescription
            }
        }

    }
    private var importControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                #if os(iOS)
                Button { naming = false; beforeRecording(); Task { await capture.start(title: name, runtime: runtime) } } label: {
                    Label("Record", systemImage: "mic.fill").frame(maxWidth: .infinity, minHeight: 28)
                }.buttonStyle(MeetingButtonStyle(palette: palette, prominent: true)).accessibilityLabel("Record meeting")
                Menu {
                    Button("Choose from Photos", systemImage: "photo.on.rectangle") { naming = false; chooseVideo = true }
                    Button("Choose from Files", systemImage: "folder") { naming = false; chooseAudio = true }
                } label: { Label("Import", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 28) }
                    .buttonStyle(MeetingButtonStyle(palette: palette)).accessibilityLabel("Import recording")
                #else
                Button { naming = false; chooseAudio = true } label: {
                    Label("Import recording…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }.buttonStyle(MeetingButtonStyle(palette: palette, prominent: true))
                #endif
            }.controlSize(.large)
            Button { showOptions.toggle(); naming = false } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                    Text(kind == "current" ? "Use what I learn" : "Keep as past context")
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption).rotationEffect(.degrees(showOptions ? 180 : 0))
                }.font(.subheadline).foregroundStyle(palette.muted).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Recording options")
            if showOptions {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Recording name (optional)", text: $title)
                        .textFieldStyle(.plain).focused($naming).padding(.vertical, 12)
                        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
                        .onSubmit { naming = false }
                    ForEach(["current", "history"], id: \.self) { option in
                        Button { kind = option } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: kind == option ? "checkmark.circle.fill" : "circle").foregroundStyle(palette.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option == "current" ? "Update what I know" : "Keep as past context").font(.subheadline.weight(.medium))
                                    Text(option == "current" ? "New details can update current facts." : "Keep the history without replacing current facts.")
                                        .font(.caption).foregroundStyle(palette.muted)
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(kind == option ? .isSelected : [])
                    }
                }.padding(16).background(palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
            Text("I keep the transcript in memory. Audio stays here; videos become audio. Let everyone know before recording.")
                .font(.caption).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func transcript(_ doc: MeetingDocument) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(doc.title).font(.title2.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Text(doc.date, style: .date).font(.caption).foregroundStyle(palette.muted)
                    Text(summary(doc)).font(.caption).foregroundStyle(palette.muted)
                }
                Spacer(minLength: 8)
                Menu {
                    ShareLink("Export transcript", item: doc.transcript)
                    if let name = doc.audioName {
                        ShareLink("Export audio", item: library.directory.appendingPathComponent(name))
                    }
                } label: { Image(systemName: "square.and.arrow.up").padding(8) }
                    .accessibilityLabel("Export conversation")
            }
            if let job = doc.processing, job.state != "done", !capture.active {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView(value: job.duration > 0 ? min(1, job.offset/job.duration) : 0)
                    Text(job.error ?? "Your audio and progress are saved.").font(.subheadline).foregroundStyle(palette.muted)
                    Button(job.state == "failed" ? "Retry transcription" : "Resume transcription") { capture.resumeImport(doc) }
                        .buttonStyle(MeetingButtonStyle(palette: palette, prominent: true))
                }
            } else if doc.processing == nil && doc.audioName != nil && doc.ended && !capture.active {
                Button("Transcribe saved audio again") { capture.resumeImport(doc) }.buttonStyle(MeetingButtonStyle(palette: palette))
            }
            Button { library.useInChat.toggle() } label: {
                Label(library.useInChat ? "Included in this chat" : "Include in this chat", systemImage: library.useInChat ? "checkmark.bubble" : "bubble.left")
            }.buttonStyle(MeetingButtonStyle(palette: palette, prominent: library.useInChat))
                .accessibilityAddTraits(library.useInChat ? .isSelected : [])
            Rectangle().fill(palette.line).frame(height: 1)
            if doc.transcript.isEmpty {
                Label("Your transcript will appear here as I work.", systemImage: "text.alignleft")
                    .font(.subheadline).foregroundStyle(palette.muted).padding(.vertical, 12)
            } else {
                Text(doc.transcript).font(.body).lineSpacing(5).textSelection(.enabled)
                    .lineLimit(expandedTranscript ? nil : 12).frame(maxWidth: .infinity, alignment: .leading)
                Button(expandedTranscript ? "Show less" : "Read full transcript") { expandedTranscript.toggle() }
                    .font(.subheadline.weight(.medium)).buttonStyle(.plain)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
    }

    private func problem(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle").font(.subheadline)
            .foregroundStyle(palette.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
    private func summary(_ doc: MeetingDocument) -> String {
        let pending = doc.batches.filter { !$0.uploaded }.count
        let state = doc.processing?.state
        let label = state == "done" ? "Transcription complete" : state == "paused" ? "Transcription paused" : state == "failed" ? "Transcription needs attention" : capture.active ? "In progress" : "Saved on this device"
        return label + (pending > 0 ? " · Memory upload pending" : doc.batches.isEmpty ? "" : " · Sent to memory")
    }
}

private struct MeetingButtonStyle: ButtonStyle {
    let palette: Palette
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.medium)).padding(14)
            .foregroundStyle(prominent ? Color.white : palette.ink)
            .background(prominent ? palette.accent : palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 0.7))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}

struct MeetingBanner: View {
    @ObservedObject var library: MeetingLibrary
    @ObservedObject var capture: MeetingCapture
    let open: () -> Void
    var body: some View {
        if capture.active || library.useInChat {
            HStack(spacing: 10) {
                Circle().fill(capture.recording ? Color.red : Color.secondary).frame(width: 7, height: 7)
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(capture.active ? capture.status : "Conversation in context").font(.subheadline.weight(.medium))
                        Text(library.selected?.title ?? "Conversation").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.buttonStyle(.plain)
                Spacer()
                if capture.recording { Button("Stop") { Task { await capture.stop(); await library.sync() } }.tint(.red) }
                else if !capture.active { Button { library.useInChat = false } label: { Image(systemName: "xmark") }.accessibilityLabel("Remove conversation from chat context") }
            }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
