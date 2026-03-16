import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsManager.self) private var settingsManager
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
            if viewModel == nil {
                let vm = ChatViewModel(modelContext: modelContext)
                vm.settingsManager = settingsManager
                viewModel = vm
            }
            checkEnvironment()
        }
        .sheet(isPresented: $showSetupSheet) {
            EnvironmentSetupView(reason: setupReason) {
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
    ContentView()
        .modelContainer(for: [Conversation.self, Message.self, Attachment.self], inMemory: true)
        .environment(SettingsManager())
}
