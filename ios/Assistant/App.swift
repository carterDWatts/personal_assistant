import SwiftUI
import Speech

@main struct AssistantApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.environment["ASSISTANT_VOICE_TEST"] == "1" {
                Text("Testing voice · microphone off").onAppear {
                    if ProcessInfo.processInfo.arguments.contains("--authorize-replay") {
                        SFSpeechRecognizer.requestAuthorization { _ in }
                    }
                }
            } else { ConversationView() }
            #else
            ConversationView()
            #endif
        }
    }
}
