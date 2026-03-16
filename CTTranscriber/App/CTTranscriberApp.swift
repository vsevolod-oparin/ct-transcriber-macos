import SwiftUI
import SwiftData

@main
struct CTTranscriberApp: App {
    private let isUITesting = CommandLine.arguments.contains("--uitesting")

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Conversation.self, Message.self, Attachment.self],
                         inMemory: isUITesting)

        Settings {
            Text("Settings will go here")
                .frame(width: 400, height: 300)
        }
    }
}
