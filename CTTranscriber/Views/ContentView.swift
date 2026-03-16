import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsManager.self) private var settingsManager
    @Binding var modelManager: ModelManager?
    @State private var viewModel: ChatViewModel?
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var showSetupSheet = false
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
        .frame(minWidth: 700, minHeight: 500)
        .onChange(of: viewModel?.selectedConversationID) { oldID, newID in
            viewModel?.conversationDidChange(from: oldID, to: newID)
            if newID != nil {
                viewModel?.requestInputFocus()
            }
        }
        .task {
            AppLogger.info("ContentView.task starting", category: "app")

            // Create ModelManager if needed
            if modelManager == nil {
                modelManager = ModelManager(settingsManager: settingsManager)
                AppLogger.info("ModelManager created", category: "app")
            }

            // Create ViewModel
            if viewModel == nil {
                let vm = ChatViewModel(modelContext: modelContext)
                vm.settingsManager = settingsManager
                vm.modelManager = modelManager
                viewModel = vm
                AppLogger.info("ViewModel created", category: "app")
            }

            checkEnvironment()
            AppLogger.info("Environment check done", category: "app")
        }
        .sheet(isPresented: $showSetupSheet) {
            EnvironmentSetupView(settingsManager: settingsManager, reason: setupReason) {
                showSetupSheet = false
            }
        }
    }

    private func checkEnvironment() {
        let status = PythonEnvironment.check(settings: settingsManager.settings.transcription)
        switch status {
        case .missing(let reason):
            setupReason = reason
            showSetupSheet = true
        case .ready, .notChecked:
            break
        }
    }
}

#Preview {
    @Previewable @State var mm: ModelManager? = nil
    let sm = SettingsManager()
    ContentView(modelManager: $mm)
        .modelContainer(for: [Conversation.self, Message.self, Attachment.self], inMemory: true)
        .environment(sm)
}
