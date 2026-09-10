import SwiftUI
import Speech

@main struct AssistantApp: App {
    @UIApplicationDelegateAdaptor(Notifications.self) var notifications
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--alarm-check") {
                if #available(iOS 26, *) { AlarmCheckView() } else { Text("Alarms require iOS 26") }
            } else if ProcessInfo.processInfo.environment["ASSISTANT_VOICE_TEST"] == "1" {
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
