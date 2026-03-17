import SwiftUI
import SwiftData

@main
struct CTTranscriberApp: App {
    private let isUITesting = CommandLine.arguments.contains("--uitesting")
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var settingsManager = SettingsManager()
    @State private var modelManager: ModelManager?

    var body: some Scene {
        WindowGroup {
            ContentView(modelManager: $modelManager, appDelegate: appDelegate)
                .environment(settingsManager)
                .preferredColorScheme(settingsManager.colorScheme)
        }
        .modelContainer(for: [Conversation.self, Message.self, Attachment.self, BackgroundTask.self],
                         inMemory: isUITesting)
        .commands {
            // Remove "New Window" from File menu — single-window app
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            SettingsView(settingsManager: settingsManager, modelManager: modelManager ?? ModelManager(settingsManager: settingsManager))
        }
    }
}

/// Handles macOS file-open events (Finder "Open With", Dock drop, `open -a` CLI).
/// Routes files to the existing window instead of creating new ones.
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var pendingOpenURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        AppLogger.info("AppDelegate: open \(urls.count) file(s)", category: "app")
        // Append to pending — ContentView picks them up via binding
        pendingOpenURLs.append(contentsOf: urls)

        // Bring existing window to front
        application.activate(ignoringOtherApps: true)
        if let window = application.windows.first(where: { $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // If user clicks Dock icon and window exists, just bring it forward
        if flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }
}
