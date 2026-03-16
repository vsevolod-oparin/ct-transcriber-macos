import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: ChatViewModel?
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        Group {
            if let viewModel {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    ConversationListView(viewModel: viewModel)
                } detail: {
                    if let conversation = viewModel.selectedConversation {
                        ChatView(conversation: conversation, viewModel: viewModel)
                    } else {
                        ContentUnavailableView(
                            "No Conversation Selected",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Select a conversation or create a new one to get started.")
                        )
                    }
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            if viewModel == nil {
                viewModel = ChatViewModel(modelContext: modelContext)
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Conversation.self, inMemory: true)
}
