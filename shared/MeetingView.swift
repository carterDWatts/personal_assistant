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
    @State private var title = ""
    @State private var kind = "current"
    #if os(iOS)
    @State private var chooseVideo = false
    @State private var video: PhotosPickerItem?
    #endif
    @State private var chooseAudio = false
    @State private var fileError = ""
    private var name: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Conversation \(Date().formatted(date: .abbreviated, time: .shortened))" : title }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Conversations").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("I can follow a meeting while you keep chatting with me. Audio stays on this device; the transcript goes into memory.").foregroundStyle(.secondary)
            TextField("Give this conversation a name", text: $title).textFieldStyle(.roundedBorder).disabled(capture.active)
            Picker("Imported recording", selection: $kind) {
                Text("Update current knowledge").tag("current")
                Text("Historical archive only").tag("history")
            }.disabled(capture.active)
            HStack(spacing: 12) {
                #if os(iOS)
                if capture.recording {
                    Button("Stop recording", systemImage: "stop.circle.fill") { Task { await capture.stop(); await library.sync() } }.tint(.red)
                } else {
                    Button("Record meeting", systemImage: "mic.fill") {
                        beforeRecording()
                        Task { await capture.start(title: name, runtime: runtime) }
                    }.disabled(capture.working)
                }
                #endif
                #if os(iOS)
                Menu {
                    Button("Choose from Photos", systemImage: "photo.on.rectangle") { chooseVideo = true }
                    Button("Choose from Files", systemImage: "folder") { chooseAudio = true }
                } label: { Label("Import recording", systemImage: "waveform.badge.plus") }.disabled(capture.active)
                #else
                Button("Import recording…", systemImage: "waveform.badge.plus") { chooseAudio = true }.disabled(capture.active)
                #endif
            }.buttonStyle(.bordered)
            #if os(iOS)
            Text("Use your phone’s microphone for an in-person conversation. Let everyone know you’re recording. You can close this panel and type to me while it runs.").font(.caption).foregroundStyle(.secondary)
            #else
            Text("Transcription runs locally while you use the chat.").font(.caption).foregroundStyle(.secondary)
            #endif
            Text("Import audio or video, including MP4. I keep a compressed audio copy and the transcript, not the video. Your original file stays untouched.").font(.caption).foregroundStyle(.secondary)
            if capture.working && !capture.recording {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(capture.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Pause") { capture.cancelImport() }
                }
            }
            if !fileError.isEmpty { Text(fileError).font(.caption).foregroundStyle(.red) }
            if !capture.error.isEmpty { Text(capture.error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if !library.notice.isEmpty { Text(library.notice).font(.callout).foregroundStyle(.secondary) }
            if let doc = library.selected {
                HStack {
                    Text(doc.title).font(.headline)
                    Spacer()
                    Menu {
                        ShareLink("Export transcript", item: doc.transcript)
                        if let name = doc.audioName {
                            ShareLink("Export audio", item: library.directory.appendingPathComponent(name))
                        }
                    } label: { Image(systemName: "square.and.arrow.up") }.help("Export conversation")
                }
                Toggle("Use this conversation in chat", isOn: $library.useInChat)
                if let job = doc.processing {
                    ProgressView(value: job.duration > 0 ? min(1, job.offset/job.duration) : 0)
                    if job.state == "paused" || job.state == "failed" {
                        HStack {
                            Text(job.error ?? "Import paused. Your audio and progress are saved.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(job.state == "failed" ? "Retry" : "Resume") { capture.resumeImport(doc) }.disabled(capture.active)
                        }
                    }
                } else if doc.audioName != nil && doc.ended && !capture.active {
                    Button("Transcribe saved audio again") { capture.resumeImport(doc) }.font(.caption)
                }
                Text(summary(doc)).font(.caption).foregroundStyle(.secondary)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(doc.transcript.isEmpty ? "Your transcript will appear here." : doc.transcript)
                                .font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("end")
                        }.padding(12)
                    }
                    .frame(minHeight: 140, maxHeight: 300)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: doc.transcript) { _ in if capture.recording { proxy.scrollTo("end", anchor: .bottom) } }
                }
            }
            if !library.documents.isEmpty {
                Text("Saved on this device").font(.subheadline.weight(.medium))
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(library.documents) { doc in
                            Button { library.selectedID = doc.id } label: {
                                HStack { Text(doc.title).lineLimit(1); Spacer(); Text(doc.date, style: .date).font(.caption).foregroundStyle(.secondary) }
                            }.buttonStyle(.plain).disabled(capture.active)
                        }
                    }
                }.frame(maxHeight: 100)
            }
            Spacer(minLength: 0)
        }.padding(22)
        #if os(macOS)
        .frame(width: 570, height: 650)
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
    private func summary(_ doc: MeetingDocument) -> String {
        let uploaded = doc.batches.filter(\.uploaded).count
        let state = doc.processing?.state
        let label = state == "done" ? "Transcription complete" : state == "paused" ? "Transcription paused" : state == "failed" ? "Transcription incomplete" : capture.active ? capture.status : "Saved on this device"
        return "\(label) · \(uploaded) of \(doc.batches.count) sections sent to memory. You can keep chatting while I work."
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
