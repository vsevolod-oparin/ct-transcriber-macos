import Foundation
import SwiftUI
import SwiftData

@Observable
final class ChatViewModel {
    var selectedConversationID: UUID?
    var messageText: String = ""
    private(set) var conversations: [Conversation] = []

    private var modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        refreshConversations()
    }

    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    func sortedMessages(for conversation: Conversation) -> [Message] {
        conversation.messages.sorted { $0.timestamp < $1.timestamp }
    }

    func createConversation() {
        let conversation = Conversation()
        modelContext.insert(conversation)
        saveContext()
        refreshConversations()
        selectedConversationID = conversation.id
    }

    func renameConversation(_ conversation: Conversation, to newTitle: String) {
        conversation.title = newTitle
        conversation.updatedAt = Date()
        saveContext()
        refreshConversations()
    }

    func deleteConversation(_ conversation: Conversation) {
        for message in conversation.messages {
            for attachment in message.attachments {
                FileStorage.delete(storedName: attachment.storedName)
            }
        }

        let wasSelected = selectedConversationID == conversation.id
        modelContext.delete(conversation)
        saveContext()
        refreshConversations()

        if wasSelected {
            selectedConversationID = conversations.first?.id
        }
    }

    func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let conversation = selectedConversation else { return }

        let message = Message(role: .user, content: text)
        conversation.messages.append(message)
        conversation.updatedAt = Date()

        autoTitleIfNeeded(conversation, firstMessageText: text)

        messageText = ""
        saveContext()
        refreshConversations()
    }

    func attachFile(from url: URL, to conversation: Conversation) {
        guard let storedName = try? FileStorage.copyToStorage(from: url) else { return }

        let kind = FileStorage.attachmentKind(for: url)
        let originalName = url.lastPathComponent
        let attachment = Attachment(kind: kind, storedName: storedName, originalName: originalName)

        let message = Message(role: .user, content: "Attached \(kind.rawValue): \(originalName)")
        message.attachments.append(attachment)
        conversation.messages.append(message)
        conversation.updatedAt = Date()
        saveContext()
        refreshConversations()
    }

    // MARK: - Private

    private static let autoTitleMaxLength = 50

    private func autoTitleIfNeeded(_ conversation: Conversation, firstMessageText: String) {
        let isFirstMessage = conversation.messages.count == 1
        let hasDefaultTitle = conversation.title == "New Conversation"
        guard isFirstMessage && hasDefaultTitle else { return }

        let truncated = String(firstMessageText.prefix(Self.autoTitleMaxLength))
        conversation.title = truncated.count < firstMessageText.count
            ? "\(truncated)..."
            : truncated
    }

    private func refreshConversations() {
        let descriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        conversations = (try? modelContext.fetch(descriptor)) ?? []
    }

    private func saveContext() {
        try? modelContext.save()
    }
}
