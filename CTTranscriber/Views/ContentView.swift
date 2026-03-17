import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsManager.self) private var settingsManager
    @Binding var modelManager: ModelManager?
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
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Select a conversation or create a new one to get started.")
                )
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
        .onChange(of: viewModel?.selectedConversationID) { oldID, newID in
            viewModel?.conversationDidChange(from: oldID, to: newID)
            if newID != nil {
                viewModel?.requestInputFocus()
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

            // Check Python environment on a background thread to avoid blocking UI.
            // PythonEnvironment.check() calls waitUntilExit() on a subprocess.
            await checkEnvironmentAsync()
            AppLogger.info("Environment check done", category: "app")
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
    ContentView(modelManager: $mm)
        .modelContainer(for: [Conversation.self, Message.self, Attachment.self, BackgroundTask.self], inMemory: true)
        .environment(sm)
}
