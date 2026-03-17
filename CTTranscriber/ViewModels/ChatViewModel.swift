import Foundation
import SwiftUI
import SwiftData

@Observable
final class ChatViewModel {
    var selectedConversationID: UUID?
    var messageText: String = ""
    private(set) var conversations: [Conversation] = []
    /// Per-conversation message drafts, keyed by conversation ID. In-memory only.
    private var drafts: [UUID: String] = [:]

    /// Called by the view when selected conversation changes.
    func conversationDidChange(from oldID: UUID?, to newID: UUID?) {
        if let oldID {
            drafts[oldID] = messageText
        }
        messageText = drafts[newID ?? UUID()] ?? ""
    }
    /// Incremented whenever the detail view should reclaim input focus.
    private(set) var focusCounter: Int = 0

    func requestInputFocus() {
        focusCounter += 1
    }

    /// True while the LLM is streaming a response.
    private(set) var isStreaming: Bool = false
    /// Accumulates the streamed response text for the current assistant message.
    private(set) var streamingText: String = ""
    /// Error message from the last LLM request, shown inline in the chat.
    var lastError: String?

    /// True while a transcription is in progress.
    private(set) var isTranscribing: Bool = false
    /// Progress of the current transcription (0.0–1.0).
    private(set) var transcriptionProgress: Double = 0

    private var modelContext: ModelContext
    private var streamingTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?

    // Dependencies injected after init
    var settingsManager: SettingsManager?
    var modelManager: ModelManager?

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
        drafts.removeValue(forKey: conversation.id)
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

    // MARK: - Retry

    func retryMessage(_ message: Message, in conversation: Conversation) {
        guard !isStreaming && !isTranscribing else { return }

        // Find the user message before this failed assistant/system message
        let sorted = sortedMessages(for: conversation)
        if message.role == .assistant || message.role == .system {
            // Remove the failed message, re-trigger LLM response
            conversation.messages.removeAll { $0.id == message.id }
            modelContext.delete(message)
            saveContext()
            refreshConversations()
            requestLLMResponse(for: conversation)
        } else if message.role == .user {
            // Re-send the user message: delete it and any following assistant message, re-send
            if let idx = sorted.firstIndex(where: { $0.id == message.id }) {
                let nextMessages = sorted.suffix(from: sorted.index(after: idx))
                for msg in nextMessages {
                    conversation.messages.removeAll { $0.id == msg.id }
                    modelContext.delete(msg)
                }
            }
            conversation.messages.removeAll { $0.id == message.id }
            modelContext.delete(message)
            saveContext()
            refreshConversations()

            // Re-create the user message and trigger LLM
            let newMessage = Message(role: .user, content: message.content)
            conversation.messages.append(newMessage)
            conversation.updatedAt = Date()
            saveContext()
            refreshConversations()
            requestLLMResponse(for: conversation)
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

        let apiKey = provider.apiKey
        guard !apiKey.isEmpty else {
            let errorMessage = Message(role: .assistant, content: "⚠ \(LLMError.noAPIKey.localizedDescription)")
            conversation.messages.append(errorMessage)
            saveContext()
            refreshConversations()
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
                    // Keep the message with error content so the user can see it and retry
                    let partial = assistantMessage.content.isEmpty ? "" : assistantMessage.content + "\n\n"
                    assistantMessage.content = "\(partial)⚠ \(error.localizedDescription)"
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

        let apiKey = provider.apiKey
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

        // Auto-transcribe audio and video files
        if kind == .audio || kind == .video {
            let audioURL = FileStorage.url(for: storedName)
            transcribeAudio(at: audioURL.path, in: conversation)
        }
    }

    // MARK: - Transcription

    func transcribeAudio(at audioPath: String, in conversation: Conversation) {
        guard !isTranscribing else {
            lastError = "A transcription is already in progress."
            return
        }

        guard let settings = settingsManager else { return }
        let transSettings = settings.settings.transcription

        // Check environment
        let envStatus = PythonEnvironment.check(settings: transSettings)
        guard case .ready = envStatus else {
            lastError = "Python environment not ready. Set up from Settings → Environment."
            return
        }

        // Check model
        guard let modelManager = modelManager else {
            AppLogger.error("modelManager is nil", category: "transcription")
            lastError = "Internal error: model manager not initialized."
            return
        }

        let selectedID = transSettings.selectedModelID
        AppLogger.info("Looking for model '\(selectedID)', statuses: \(modelManager.modelStatuses.keys.sorted())", category: "transcription")

        guard let modelPath = modelManager.modelPath(for: selectedID) else {
            AppLogger.error("Model '\(selectedID)' not found. Status: \(String(describing: modelManager.modelStatuses[selectedID]))", category: "transcription")
            lastError = TranscriptionError.modelNotDownloaded.localizedDescription
            return
        }

        AppLogger.info("Using model at: \(modelPath)", category: "transcription")

        isTranscribing = true
        transcriptionProgress = 0

        // Create a placeholder system message for the transcription
        let transcriptMessage = Message(role: .assistant, content: "Transcribing...")
        conversation.messages.append(transcriptMessage)
        saveContext()
        refreshConversations()

        transcriptionTask = Task { [weak self] in
            let stream = TranscriptionService.transcribe(
                audioPath: audioPath,
                modelPath: modelPath,
                settings: transSettings
            )

            do {
                var result: TranscriptionService.TranscriptionResult?

                for try await progress in stream {
                    guard let self, !Task.isCancelled else { break }

                    await MainActor.run {
                        switch progress {
                        case .started(let language, let duration):
                            transcriptMessage.content = "Transcribing... (detected: \(language), \(String(format: "%.0f", duration))s)"
                        case .segment(_, let text, let prog):
                            self.transcriptionProgress = prog
                            transcriptMessage.content = "Transcribing (\(Int(prog * 100))%)...\n\n\(text)"
                        case .completed(let res):
                            result = res
                        case .error(let msg):
                            self.lastError = msg
                        }
                    }
                }

                guard let self else { return }
                await MainActor.run {
                    if let result {
                        transcriptMessage.content = self.formatTranscriptionResult(result)
                    }
                    self.isTranscribing = false
                    self.transcriptionProgress = 0
                    self.saveContext()
                    self.refreshConversations()
                }
            } catch let error as TranscriptionError where error.localizedDescription == TranscriptionError.cancelled.localizedDescription {
                guard let self else { return }
                await MainActor.run {
                    transcriptMessage.content = "Transcription cancelled."
                    self.isTranscribing = false
                    self.transcriptionProgress = 0
                    self.saveContext()
                    self.refreshConversations()
                }
            } catch {
                guard let self else { return }
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    transcriptMessage.content = "Transcription failed."
                    self.isTranscribing = false
                    self.transcriptionProgress = 0
                    self.saveContext()
                    self.refreshConversations()
                }
            }
        }
    }

    func stopTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }

    private func formatTranscriptionResult(_ result: TranscriptionService.TranscriptionResult) -> String {
        var text = "**Transcription** (\(result.language), \(String(format: "%.1f", result.elapsed))s)\n\n"
        text += result.formattedTranscript
        return text
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
