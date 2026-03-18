import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsManager.self) private var settingsManager
    @Binding var modelManager: ModelManager?
    /// AppDelegate receives file-open events from macOS and queues URLs here.
    @ObservedObject var appDelegate: AppDelegate
    @State private var viewModel: ChatViewModel?
    @State private var taskManager: TaskManager?
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var showSetupSheet = false
    @State private var showTaskManager = false
    @State private var setupReason = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            if let viewModel {
                ConversationListView(viewModel: viewModel)
            }
        } detail: {
            if let viewModel, let conversation = viewModel.selectedConversation {
                ChatView(conversation: conversation, viewModel: viewModel)
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 36 * CGFloat(settingsManager.fontScale)))
                        .foregroundStyle(.secondary)
                    Text("No Conversation Selected")
                        .font(ScaledFont(scale: settingsManager.fontScale).headline)
                    Text("Select a conversation, create a new one, or drop audio files here.")
                        .font(ScaledFont(scale: settingsManager.fontScale).caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleEmptyStateDrop(providers: providers)
                    return true
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showTaskManager = true } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "list.bullet.rectangle")
                        if let tm = taskManager, tm.activeCount > 0 {
                            Text("\(tm.activeCount)")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                                .padding(2)
                                .background(Color.red)
                                .clipShape(Circle())
                                .offset(x: 6, y: -6)
                        }
                    }
                }
                .help("Background Tasks")
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onKeyPress(.tab) {
            // Tab toggles between sidebar and user input.
            // Detect current focus by checking if the first responder is a text input
            // (TextEditor / NSTextView = user input focused) vs anything else (sidebar).
            guard let window = NSApp.keyWindow else { return .handled }
            let isInputFocused = window.firstResponder is NSTextView

            if isInputFocused {
                // Input → sidebar
                if let sidebarView = findSidebarListView(in: window.contentView) {
                    window.makeFirstResponder(sidebarView)
                }
            } else {
                // Sidebar → input
                viewModel?.requestInputFocus()
            }
            return .handled
        }
        .onChange(of: viewModel?.selectedConversationID) { oldID, newID in
            viewModel?.conversationDidChange(from: oldID, to: newID)
        }
        .task {
            AppLogger.info("ContentView.task starting", category: "app")

            if modelManager == nil {
                modelManager = ModelManager(settingsManager: settingsManager)
                AppLogger.info("ModelManager created", category: "app")
            }

            if taskManager == nil {
                taskManager = TaskManager(modelContext: modelContext)
                AppLogger.info("TaskManager created", category: "app")
            }

            if viewModel == nil {
                let vm = ChatViewModel(modelContext: modelContext,
                                       settingsManager: settingsManager,
                                       modelManager: modelManager!)
                vm.taskManager = taskManager
                viewModel = vm
                AppLogger.info("ViewModel created", category: "app")
            }

            // Process any files that were opened before the ViewModel was ready
            processPendingURLs()

            // Check Python environment on a background thread to avoid blocking UI.
            // PythonEnvironment.check() calls waitUntilExit() on a subprocess.
            await checkEnvironmentAsync()
            AppLogger.info("Environment check done", category: "app")
        }
        .onChange(of: appDelegate.pendingOpenURLs) { _, urls in
            // Handle URLs that arrive after startup (e.g., second file open from Finder)
            if !urls.isEmpty {
                processPendingURLs()
            }
        }
        .sheet(isPresented: $showSetupSheet) {
            EnvironmentSetupView(settingsManager: settingsManager, reason: setupReason) {
                showSetupSheet = false
            }
        }
        .sheet(isPresented: $showTaskManager) {
            if let taskManager {
                TaskManagerView(taskManager: taskManager)
            }
        }
    }

    private func handleEmptyStateDrop(providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    if let data = data as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            guard let viewModel, !urls.isEmpty else { return }
            viewModel.openFiles(urls: urls)
        }
    }

    private func processPendingURLs() {
        guard let viewModel, !appDelegate.pendingOpenURLs.isEmpty else { return }
        let urls = appDelegate.pendingOpenURLs
        appDelegate.pendingOpenURLs.removeAll()
        viewModel.openFiles(urls: urls)
        AppLogger.info("Processed \(urls.count) file(s) from Finder/Dock", category: "app")
    }

    /// Finds the sidebar's NSOutlineView (SwiftUI List is backed by NSOutlineView on macOS).
    private func findSidebarListView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        // SwiftUI List on macOS is backed by NSOutlineView
        if view is NSOutlineView {
            return view
        }
        for subview in view.subviews {
            if let found = findSidebarListView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func checkEnvironmentAsync() async {
        let settings = settingsManager.settings.transcription
        // Run the blocking subprocess check off the main thread
        let status = await Task.detached(priority: .userInitiated) {
            PythonEnvironment.check(settings: settings)
        }.value
        await MainActor.run {
            switch status {
            case .missing(let reason):
                setupReason = reason
                showSetupSheet = true
            case .ready, .notChecked:
                break
            }
        }
    }
}

#Preview {
    @Previewable @State var mm: ModelManager? = nil
    let sm = SettingsManager()
    ContentView(modelManager: $mm, appDelegate: AppDelegate())
        .modelContainer(for: [Conversation.self, Message.self, Attachment.self, BackgroundTask.self], inMemory: true)
        .environment(sm)
}
