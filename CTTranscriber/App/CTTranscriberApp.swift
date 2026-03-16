import SwiftUI
import SwiftData

@main
struct CTTranscriberApp: App {
    private let isUITesting = CommandLine.arguments.contains("--uitesting")
    @State private var settingsManager = SettingsManager()
    @State private var modelManager: ModelManager?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settingsManager)
                .preferredColorScheme(settingsManager.colorScheme)
                .task {
                    if modelManager == nil {
                        modelManager = ModelManager(settingsManager: settingsManager)
                    }
                }
        }
        .modelContainer(for: [Conversation.self, Message.self, Attachment.self],
                         inMemory: isUITesting)

        Settings {
            SettingsView(settingsManager: settingsManager, modelManager: modelManager)
        }
    }
}
