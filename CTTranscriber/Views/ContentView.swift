import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsManager.self) private var settingsManager
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Binding var modelManager: ModelManager?
    /// AppDelegate receives file-open events from macOS and queues URLs here.
    @ObservedObject var appDelegate: AppDelegate
    @State private var viewModel: ChatViewModel?
    @State private var taskManager: TaskManager?
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var showTaskManager = false

    var body: some View {
        mainContent
            .modifier(ContentViewModifiers(
                viewModel: $viewModel,
                taskManager: $taskManager,
                modelManager: $modelManager,
                appDelegate: appDelegate,
                showTaskManager: $showTaskManager,
                settingsManager: settingsManager,
                modelContext: modelContext,
                conversations: conversations
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
                if let sidebarView = ViewUtils.findOutlineView(in: window.contentView) {
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
        // Use a class-based container to avoid "mutation of captured var" in concurrent closures.
        final class URLCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [URL] = []
            func append(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
            var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
        }
        let collector = URLCollector()
        let group = DispatchGroup()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    if let data = data as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        collector.append(url)
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let urls = collector.urls
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
}

// MARK: - Modifiers (extracted to help type checker)

private struct ContentViewModifiers: ViewModifier {
    @Binding var viewModel: ChatViewModel?
    @Binding var taskManager: TaskManager?
    @Binding var modelManager: ModelManager?
    @ObservedObject var appDelegate: AppDelegate
    @Binding var showTaskManager: Bool
    let settingsManager: SettingsManager
    let modelContext: ModelContext
    let conversations: [Conversation]

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel?.selectedConversationID) { oldID, newID in
                viewModel?.conversationDidChange(from: oldID, to: newID)
                if oldID != newID {
                    AudioPlaybackManager.shared.stopAll()
                }
            }
            .onChange(of: conversations) { _, newConversations in
                viewModel?.conversations = newConversations
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
                    vm.conversations = conversations
                    viewModel = vm
                    AppLogger.info("ViewModel created", category: "app")
                }
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
