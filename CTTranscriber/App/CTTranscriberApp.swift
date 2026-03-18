import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@main
struct CTTranscriberApp: App {
    private let isUITesting = CommandLine.arguments.contains("--uitesting")
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var settingsManager = SettingsManager()
    @State private var modelManager: ModelManager?
    @State private var showAbout = false
    @State private var showOpenPanel = false

    var body: some Scene {
        WindowGroup {
            ContentView(modelManager: $modelManager, appDelegate: appDelegate)
                .environment(settingsManager)
                .environment(\.fontScale, settingsManager.fontScale)
                .preferredColorScheme(settingsManager.colorScheme)
                .font(.system(size: CGFloat(NSFont.systemFontSize) * CGFloat(settingsManager.fontScale)))
                .sheet(isPresented: $showAbout) {
                    AboutView()
                }
        }
        .modelContainer(for: [Conversation.self, Message.self, Attachment.self, BackgroundTask.self],
                         inMemory: isUITesting)
        .commands {
            // Replace default New Window with New Conversation
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    NotificationCenter.default.post(name: .createNewConversation, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            // File menu: Open Audio
            CommandGroup(after: .newItem) {
                Button("Open Audio/Video...") {
                    openAudioFiles()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // View menu: Font scaling
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

            // Help menu: About
            CommandGroup(replacing: .appInfo) {
                Button("About CT Transcriber") {
                    showAbout = true
                }
            }
        }

        Settings {
            SettingsView(settingsManager: settingsManager, modelManager: modelManager ?? ModelManager(settingsManager: settingsManager))
                .environment(\.fontScale, settingsManager.fontScale)
                .font(.system(size: CGFloat(NSFont.systemFontSize) * CGFloat(settingsManager.fontScale)))
        }
    }

    private func openAudioFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .audio, .movie, .video, .mpeg4Movie, .quickTimeMovie,
            UTType(filenameExtension: "webm") ?? .movie,
            UTType(filenameExtension: "mkv") ?? .movie,
        ]
        panel.message = "Select audio or video files to transcribe"

        if panel.runModal() == .OK {
            appDelegate.pendingOpenURLs.append(contentsOf: panel.urls)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let createNewConversation = Notification.Name("createNewConversation")
}

// MARK: - About View

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)

            Text("CT Transcriber")
                .font(.title)
                .fontWeight(.bold)

            Text("Version \(version) (\(build))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Audio & video transcription powered by CTranslate2 Metal backend on Apple Silicon.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300)

            Divider()

            VStack(spacing: 4) {
                Text("CTranslate2 Metal Backend")
                    .font(.caption)
                    .fontWeight(.medium)
                Text("faster-whisper · Whisper Models")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("OK") { dismiss() }
                .keyboardShortcut(.return)
        }
        .padding(24)
        .frame(width: 360)
        .onExitCommand { dismiss() }
    }
}

// MARK: - App Delegate

/// Handles macOS file-open events (Finder "Open With", Dock drop, `open -a` CLI).
/// Routes files to the existing window instead of creating new ones.
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var pendingOpenURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        AppLogger.info("AppDelegate: open \(urls.count) file(s)", category: "app")
        pendingOpenURLs.append(contentsOf: urls)

        application.activate(ignoringOtherApps: true)
        if let window = application.windows.first(where: { $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }
}
