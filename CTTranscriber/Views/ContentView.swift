import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Text("Conversations will go here")
                    .foregroundStyle(.secondary)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
            .toolbar {
                ToolbarItem {
                    Button(action: {}) {
                        Label("New Conversation", systemImage: "plus")
                    }
                }
            }
        } detail: {
            ContentUnavailableView(
                "No Conversation Selected",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Select a conversation or create a new one to get started.")
            )
        }
        .navigationTitle("CT Transcriber")
        .frame(minWidth: 700, minHeight: 500)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Conversation.self, inMemory: true)
}
