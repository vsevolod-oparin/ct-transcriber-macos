import SwiftUI
import SwiftData

@main
struct CTTranscriberApp: App {
    private let isUITesting = CommandLine.arguments.contains("--uitesting")
    @State private var settingsManager = SettingsManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settingsManager)
                .preferredColorScheme(settingsManager.colorScheme)
        }
        .modelContainer(for: [Conversation.self, Message.self, Attachment.self],
                         inMemory: isUITesting)

        Settings {
            SettingsView(settingsManager: settingsManager)
        }
    }
}
