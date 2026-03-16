import Foundation
import SwiftUI
import SwiftData

@Observable
final class ChatViewModel {
    var selectedConversationID: UUID?
    var messageText: String = ""
    private(set) var conversations: [Conversation] = []

    /// True while the LLM is streaming a response.
    private(set) var isStreaming: Bool = false
    /// Accumulates the streamed response text for the current assistant message.
    private(set) var streamingText: String = ""
    /// Error message from the last LLM request, shown inline in the chat.
    var lastError: String?

    private var modelContext: ModelContext
    private var streamingTask: Task<Void, Never>?

    // Dependencies injected after init
    var settingsManager: SettingsManager?

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

    // MARK: - Conversation CRUD

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

    // MARK: - Send Message + LLM Streaming

    func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let conversation = selectedConversation else { return }
        guard !isStreaming else { return }

        let userMessage = Message(role: .user, content: text)
        conversation.messages.append(userMessage)
        conversation.updatedAt = Date()
        autoTitleIfNeeded(conversation, firstMessageText: text)
        messageText = ""
        lastError = nil
        saveContext()
        refreshConversations()

        requestLLMResponse(for: conversation)
    }

    func stopStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        finalizeStreaming()
    }

    private func requestLLMResponse(for conversation: Conversation) {
        guard let settings = settingsManager,
              let provider = settings.activeProvider else { return }

        let apiKey = settings.apiKey(for: provider)
        guard !apiKey.isEmpty else {
            lastError = LLMError.noAPIKey.localizedDescription
            return
        }

        let service = LLMServiceFactory.service(for: provider)
        let messages = buildMessageDTOs(for: conversation)

        isStreaming = true
        streamingText = ""

        // Create a placeholder assistant message
        let assistantMessage = Message(role: .assistant, content: "")
        conversation.messages.append(assistantMessage)
        saveContext()
        refreshConversations()

        streamingTask = Task { [weak self] in
            let stream = service.streamCompletion(
                messages: messages,
                model: provider.defaultModel,
                temperature: provider.temperature,
                maxTokens: provider.maxTokens,
                baseURL: provider.baseURL,
                completionsPath: provider.completionsPath,
                apiKey: apiKey,
                extraHeaders: provider.extraHeaders
            )

            do {
                for try await token in stream {
                    guard let self, !Task.isCancelled else { break }
                    await MainActor.run {
                        self.streamingText += token
                        assistantMessage.content = self.streamingText
                    }
                }

                guard let self else { return }
                await MainActor.run {
                    self.finalizeStreaming()
                    self.autoNameConversation(conversation)
                }
            } catch let error as LLMError where error.localizedDescription == LLMError.cancelled.localizedDescription {
                guard let self else { return }
                await MainActor.run {
                    self.finalizeStreaming()
                }
            } catch {
                guard let self else { return }
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    // Remove empty assistant message on error
                    if assistantMessage.content.isEmpty {
                        conversation.messages.removeAll { $0.id == assistantMessage.id }
                        self.modelContext.delete(assistantMessage)
                    }
                    self.finalizeStreaming()
                }
            }
        }
    }

    private func finalizeStreaming() {
        isStreaming = false
        streamingText = ""
        saveContext()
        refreshConversations()
    }

    private func buildMessageDTOs(for conversation: Conversation) -> [ChatMessageDTO] {
        sortedMessages(for: conversation)
            .filter { $0.role != .system || !$0.content.isEmpty }
            .compactMap { message in
                guard !message.content.isEmpty else { return nil }
                // Don't include the empty placeholder assistant message
                if message.role == .assistant && message.content.isEmpty { return nil }
                return ChatMessageDTO(role: message.role.rawValue, content: message.content)
            }
    }

    // MARK: - Auto-naming

    private static let autoTitleMaxLength = 50
    private static let autoNamePrompt = "Give a short title (max 6 words) for this conversation. Reply with ONLY the title, no quotes or punctuation."

    private func autoTitleIfNeeded(_ conversation: Conversation, firstMessageText: String) {
        let isFirstMessage = conversation.messages.count == 1
        let hasDefaultTitle = conversation.title == "New Conversation"
        guard isFirstMessage && hasDefaultTitle else { return }

        let truncated = String(firstMessageText.prefix(Self.autoTitleMaxLength))
        conversation.title = truncated.count < firstMessageText.count
            ? "\(truncated)..."
            : truncated
    }

    /// After first assistant response, ask the LLM to suggest a title.
    private func autoNameConversation(_ conversation: Conversation) {
        guard let settings = settingsManager,
              let provider = settings.activeProvider else { return }

        let assistantMessages = conversation.messages.filter { $0.role == .assistant }
        guard assistantMessages.count == 1 else { return }

        let apiKey = settings.apiKey(for: provider)
        guard !apiKey.isEmpty else { return }

        let service = LLMServiceFactory.service(for: provider)

        var namingMessages = buildMessageDTOs(for: conversation)
        namingMessages.append(ChatMessageDTO(role: "user", content: Self.autoNamePrompt))

        Task {
            var title = ""
            let stream = service.streamCompletion(
                messages: namingMessages,
                model: provider.defaultModel,
                temperature: 0.3,
                maxTokens: 30,
                baseURL: provider.baseURL,
                completionsPath: provider.completionsPath,
                apiKey: apiKey,
                extraHeaders: provider.extraHeaders
            )

            do {
                for try await token in stream {
                    title += token
                }
            } catch {
                return // silently fail — truncated title from first message is fine
            }

            let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
            guard !cleaned.isEmpty else { return }

            await MainActor.run {
                conversation.title = String(cleaned.prefix(Self.autoTitleMaxLength))
                conversation.updatedAt = Date()
                self.saveContext()
                self.refreshConversations()
            }
        }
    }

    // MARK: - File Attachment

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
