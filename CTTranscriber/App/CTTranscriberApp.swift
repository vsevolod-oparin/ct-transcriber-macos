import SwiftUI
import SwiftData

@main
struct CTTranscriberApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Conversation.self, Message.self, Attachment.self])

        Settings {
            Text("Settings will go here")
                .frame(width: 400, height: 300)
        }
    }
}
