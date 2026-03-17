import SwiftUI
import SwiftData

@main
struct CTTranscriberApp: App {
    private let isUITesting = CommandLine.arguments.contains("--uitesting")
    @State private var settingsManager = SettingsManager()
    @State private var modelManager: ModelManager?

    var body: some Scene {
        WindowGroup {
            ContentView(modelManager: $modelManager)
                .environment(settingsManager)
                .preferredColorScheme(settingsManager.colorScheme)
        }
        .modelContainer(for: [Conversation.self, Message.self, Attachment.self, BackgroundTask.self],
                         inMemory: isUITesting)

        Settings {
            SettingsView(settingsManager: settingsManager, modelManager: modelManager ?? ModelManager(settingsManager: settingsManager))
        }
    }
}
