import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsManager.self) private var settingsManager
    @State private var viewModel: ChatViewModel?
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

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
        .task {
            if viewModel == nil {
                let vm = ChatViewModel(modelContext: modelContext)
                vm.settingsManager = settingsManager
                viewModel = vm
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Conversation.self, Message.self, Attachment.self], inMemory: true)
        .environment(SettingsManager())
}
