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
        mainContent
            .modifier(ContentViewModifiers(
                viewModel: $viewModel,
                taskManager: $taskManager,
                modelManager: $modelManager,
                appDelegate: appDelegate,
                showSetupSheet: $showSetupSheet,
                showTaskManager: $showTaskManager,
                setupReason: $setupReason,
                settingsManager: settingsManager,
                modelContext: modelContext
            ))
    }

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            if let viewModel {
                ConversationListView(viewModel: viewModel)
            }
        } detail: {
            if let viewModel, let conversation = viewModel.selectedConversation {
                ChatView(conversation: conversation, viewModel: viewModel)
            } else {
                emptyStateView
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
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onKeyPress(.tab) {
            guard let window = NSApp.keyWindow else { return .handled }
            let isInputFocused = window.firstResponder is NSTextView

            if isInputFocused {
                if let sidebarView = findSidebarListView(in: window.contentView) {
                    window.makeFirstResponder(sidebarView)
                }
            } else {
                viewModel?.requestInputFocus()
            }
            return .handled
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
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

    func processPendingURLs() {
        guard let viewModel, !appDelegate.pendingOpenURLs.isEmpty else { return }
        let urls = appDelegate.pendingOpenURLs
        appDelegate.pendingOpenURLs.removeAll()
        viewModel.openFiles(urls: urls)
        AppLogger.info("Processed \(urls.count) file(s) from Finder/Dock", category: "app")
    }

    /// Finds the sidebar's NSOutlineView (SwiftUI List is backed by NSOutlineView on macOS).
    private func findSidebarListView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
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
}

// MARK: - Modifiers (extracted to help type checker)

private struct ContentViewModifiers: ViewModifier {
    @Binding var viewModel: ChatViewModel?
    @Binding var taskManager: TaskManager?
    @Binding var modelManager: ModelManager?
    @ObservedObject var appDelegate: AppDelegate
    @Binding var showSetupSheet: Bool
    @Binding var showTaskManager: Bool
    @Binding var setupReason: String
    let settingsManager: SettingsManager
    let modelContext: ModelContext

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel?.selectedConversationID) { oldID, newID in
                viewModel?.conversationDidChange(from: oldID, to: newID)
                if oldID != newID {
                    AudioPlaybackManager.shared.stopAll()
                }
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

                await checkEnvironmentAsync()
                AppLogger.info("Environment check done", category: "app")
            }
            .onChange(of: appDelegate.pendingOpenURLs) { _, urls in
                if !urls.isEmpty {
                    processPendingURLs()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .createNewConversation)) { _ in
                viewModel?.createConversation()
            }
            .onReceive(NotificationCenter.default.publisher(for: .videoAspectRatioDidChange)) { _ in
                viewModel?.refreshAfterVideoChange()
            }
            .modifier(ExportImportNotifications(viewModel: $viewModel))
            .sheet(isPresented: $showSetupSheet) {
                EnvironmentSetupView(settingsManager: settingsManager, reason: setupReason) {
                    showSetupSheet = false
                    PythonEnvironment.invalidateCache()
                    modelManager?.refreshStatuses()
                }
            }
            .sheet(isPresented: $showTaskManager) {
                if let taskManager {
                    TaskManagerView(taskManager: taskManager)
                }
            }
    }

    private func processPendingURLs() {
        guard let viewModel, !appDelegate.pendingOpenURLs.isEmpty else { return }
        let urls = appDelegate.pendingOpenURLs
        appDelegate.pendingOpenURLs.removeAll()
        viewModel.openFiles(urls: urls)
        AppLogger.info("Processed \(urls.count) file(s) from Finder/Dock", category: "app")
    }

    private func checkEnvironmentAsync() async {
        let settings = settingsManager.settings.transcription
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

/// Separate modifier for export/import notifications to reduce type-checker pressure.
private struct ExportImportNotifications: ViewModifier {
    @Binding var viewModel: ChatViewModel?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .exportConversationJSON)) { _ in
                if let convo = viewModel?.selectedConversation {
                    viewModel?.exportConversationJSON(convo)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportConversationMarkdown)) { _ in
                if let convo = viewModel?.selectedConversation {
                    viewModel?.exportConversationMarkdown(convo)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportConversationPDF)) { _ in
                if let convo = viewModel?.selectedConversation {
                    viewModel?.exportConversationPDF(convo)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportAllConversations)) { _ in
                viewModel?.exportAllConversations()
            }
            .onReceive(NotificationCenter.default.publisher(for: .importConversation)) { _ in
                viewModel?.importConversation()
            }
    }
}

#Preview {
    @Previewable @State var mm: ModelManager? = nil
    let sm = SettingsManager()
    ContentView(modelManager: $mm, appDelegate: AppDelegate())
        .modelContainer(CTTranscriberApp.makeModelContainer(inMemory: true))
        .environment(sm)
}
