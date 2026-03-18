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
                .environment(\.fontScale, settingsManager.fontScale)
                .preferredColorScheme(settingsManager.colorScheme)
                .font(.system(size: CGFloat(NSFont.systemFontSize) * CGFloat(settingsManager.fontScale)))
        }
        .modelContainer(for: [Conversation.self, Message.self, Attachment.self, BackgroundTask.self],
                         inMemory: isUITesting)
        .commands {
            // Remove "New Window" from File menu — single-window app
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .textFormatting) {
                Button("Increase Font Size") {
                    settingsManager.increaseFontScale()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Decrease Font Size") {
                    settingsManager.decreaseFontScale()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Reset Font Size") {
                    settingsManager.settings.general.fontScale = 1.0
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            SettingsView(settingsManager: settingsManager, modelManager: modelManager ?? ModelManager(settingsManager: settingsManager))
                .environment(\.fontScale, settingsManager.fontScale)
                .font(.system(size: CGFloat(NSFont.systemFontSize) * CGFloat(settingsManager.fontScale)))
        }
    }
}

/// Maps a font scale factor (0.7–2.0) to the nearest DynamicTypeSize.
private func dynamicTypeForScale(_ scale: Double) -> DynamicTypeSize {
    switch scale {
    case ..<0.8:    return .xSmall
    case ..<0.9:    return .small
    case ..<1.0:    return .medium
    case ..<1.1:    return .large       // default
    case ..<1.2:    return .xLarge
    case ..<1.3:    return .xxLarge
    case ..<1.5:    return .xxxLarge
    case ..<1.7:    return .accessibility1
    case ..<1.9:    return .accessibility2
    default:        return .accessibility3
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
