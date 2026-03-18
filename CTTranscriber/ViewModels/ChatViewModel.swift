import Foundation
import SwiftUI
import SwiftData

@Observable
final class ChatViewModel {
    /// The conversation currently shown in the detail view. Set on click or Enter.
    var selectedConversationID: UUID?
    /// Conversations highlighted in the sidebar (for multi-select and delete). Arrow keys move this.
    var highlightedIDs: Set<UUID> = []
    /// Index of the keyboard cursor in the conversations array — the "anchor" for Shift+Arrow extension.
    var highlightCursor: Int = 0
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
    /// Incremented to trigger scroll-to-top in the chat table.
    private(set) var scrollToTopTrigger: Int = 0
    /// Incremented to trigger scroll-to-bottom in the chat table.
    private(set) var scrollToBottomTrigger: Int = 0

    func scrollToTop() { scrollToTopTrigger += 1 }
    func scrollToBottom() { scrollToBottomTrigger += 1 }

    func requestInputFocus() {
        focusCounter += 1
    }

    /// True while the LLM is streaming a response.
    private(set) var isStreaming: Bool = false
    /// Accumulates the streamed response text for the current assistant message.
    private(set) var streamingText: String = ""
    /// Error message from the last LLM request, shown inline in the chat.
    var lastError: String?

    /// Seek request: when a user clicks a timestamp in a transcript, this is set to
    /// (storedName, timeInSeconds) so the audio player can seek to that position.
    var seekRequest: (storedName: String, time: TimeInterval)?

    /// Number of active transcriptions.
    private(set) var activeTranscriptionCount: Int = 0
    /// True while any transcription is in progress.
    var isTranscribing: Bool { activeTranscriptionCount > 0 }
    /// Progress of the most recent transcription (0.0–1.0).
    private(set) var transcriptionProgress: Double = 0

    private var modelContext: ModelContext
    private var streamingTask: Task<Void, Never>?
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingTranscriptions: [(audioPath: String, displayName: String, conversation: Conversation, message: Message)] = []

    // Dependencies — constructor-injected for testability
    let settingsManager: SettingsManager
    let modelManager: ModelManager
    var taskManager: TaskManager?

    init(modelContext: ModelContext, settingsManager: SettingsManager, modelManager: ModelManager) {
        self.modelContext = modelContext
        self.settingsManager = settingsManager
        self.modelManager = modelManager
        refreshConversations()
    }

    deinit {
        AppLogger.debug("ChatViewModel deinit", category: "lifecycle")
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

    // MARK: - Sidebar Highlight / Activate

    /// Activates the first highlighted conversation (Enter key in sidebar).
    func activateHighlighted() {
        guard let firstID = highlightedIDs.first,
              conversations.contains(where: { $0.id == firstID }) else { return }
        selectedConversationID = firstID
        requestInputFocus()
    }

    /// Deletes all highlighted conversations.
    func deleteHighlightedConversations() {
        let toDelete = conversations.filter { highlightedIDs.contains($0.id) }
        for conversation in toDelete {
            deleteConversation(conversation)
        }
        highlightedIDs.removeAll()
    }

    /// Moves highlight up or down. If `extend` is true (Shift held), extends the selection.
    func moveHighlight(direction: Int, extend: Bool) {
        guard !conversations.isEmpty else { return }

        // Clamp cursor to valid range
        highlightCursor = min(max(highlightCursor, 0), conversations.count - 1)

        let newIndex = min(max(highlightCursor + direction, 0), conversations.count - 1)
        highlightCursor = newIndex

        if extend {
            // Add the new position to the set — builds up a contiguous range
            highlightedIDs.insert(conversations[newIndex].id)
        } else {
            highlightedIDs = [conversations[newIndex].id]
        }
    }

    /// Sets the cursor to match a conversation ID (e.g., after a click).
    func setCursor(to conversationID: UUID) {
        if let idx = conversations.firstIndex(where: { $0.id == conversationID }) {
            highlightCursor = idx
        }
    }

    func renameConversation(_ conversation: Conversation, to newTitle: String) {
        conversation.title = newTitle
        conversation.updatedAt = Date()
        saveContext()
        refreshConversations()
    }

    func deleteConversation(_ conversation: Conversation) {
        drafts.removeValue(forKey: conversation.id)

        // Cancel and clean up any active transcription tasks for this conversation's messages
        let messageIDs = Set(conversation.messages.map(\.id))
        cancelTranscriptionTasks(for: messageIDs)

        // Remove pending transcriptions for this conversation
        pendingTranscriptions.removeAll { $0.conversation.id == conversation.id }

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

    /// Cancels transcription tasks whose message IDs match the given set.
    private func cancelTranscriptionTasks(for messageIDs: Set<UUID>) {
        // transcriptionTasks is keyed by internal task UUID, not message UUID.
        // We need to cancel all tasks and let finishTranscription handle cleanup.
        // For now, cancel all if the conversation being deleted has active transcriptions.
        // A more precise mapping would require tracking conversation ID per task.
        if !messageIDs.isEmpty {
            for (taskID, task) in transcriptionTasks {
                task.cancel()
                transcriptionTasks.removeValue(forKey: taskID)
            }
            activeTranscriptionCount = 0
            transcriptionProgress = 0
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
        guard let provider = settingsManager.activeProvider else { return }

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
        guard let provider = settingsManager.activeProvider else { return }

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

    // MARK: - Open Files (Finder / Dock drop / onOpenURL)

    /// Opens files from external sources (Finder "Open With", Dock drop, etc.).
    /// Creates a new conversation and attaches all files to it.
    func openFiles(urls: [URL]) {
        guard !urls.isEmpty else { return }

        let conversation = Conversation()
        // Title from first filename
        let firstName = urls.first?.deletingPathExtension().lastPathComponent ?? "Audio"
        let suffix = urls.count > 1 ? " (+\(urls.count - 1) more)" : ""
        conversation.title = "\(firstName)\(suffix)"

        modelContext.insert(conversation)
        saveContext()
        refreshConversations()
        selectedConversationID = conversation.id

        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            attachFile(from: url, to: conversation)
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
            transcribeAudio(at: audioURL.path, originalName: originalName, in: conversation)
        }
    }

    // MARK: - Transcription

    func transcribeAudio(at audioPath: String, originalName: String? = nil, in conversation: Conversation) {
        // Create placeholder message immediately so it appears right after the audio
        let displayName = originalName ?? (audioPath as NSString).lastPathComponent
        let transcriptMessage = Message(role: .assistant, content: "⏳ Queued: \(displayName)")
        conversation.messages.append(transcriptMessage)
        saveContext()
        refreshConversations()

        // Queue if at capacity
        if activeTranscriptionCount >= settingsManager.settings.transcription.maxParallelTranscriptions {
            pendingTranscriptions.append((audioPath: audioPath, displayName: displayName, conversation: conversation, message: transcriptMessage))
            AppLogger.info("Transcription queued (\(pendingTranscriptions.count) pending)", category: "transcription")
            return
        }

        startTranscription(audioPath: audioPath, displayName: displayName, conversation: conversation, transcriptMessage: transcriptMessage)
    }

    private func startTranscription(audioPath: String, displayName: String, conversation: Conversation, transcriptMessage: Message) {
        let transSettings = settingsManager.settings.transcription

        let envStatus = PythonEnvironment.check(settings: transSettings)
        guard case .ready = envStatus else {
            transcriptMessage.content = "⚠ Python environment not ready. Set up from Settings → Environment."
            saveContext()
            refreshConversations()
            return
        }

        let selectedID = transSettings.selectedModelID
        guard let modelPath = modelManager.modelPath(for: selectedID) else {
            transcriptMessage.content = "⚠ \(TranscriptionError.modelNotDownloaded.localizedDescription)"
            saveContext()
            refreshConversations()
            return
        }

        activeTranscriptionCount += 1
        transcriptionProgress = 0
        transcriptMessage.content = "Transcribing..."

        let bgTask = taskManager?.createTask(kind: .transcription, title: displayName, conversationTitle: conversation.title)
        let taskID = UUID()

        transcriptionTasks[taskID] = Task { [weak self] in
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
                            transcriptMessage.content = "Transcribing... (detected: \(language), \(Self.formatDuration(duration)))"
                            bgTask?.status = .running
                        case .segment(_, let text, let prog):
                            self.transcriptionProgress = prog
                            transcriptMessage.content = "Transcribing (\(Int(prog * 100))%)...\n\n\(text)"
                            bgTask?.progress = prog
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
                        bgTask?.status = .completed
                        bgTask?.progress = 1.0
                    }
                    self.finishTranscription(taskID: taskID)
                }
            } catch let error as TranscriptionError where error.localizedDescription == TranscriptionError.cancelled.localizedDescription {
                guard let self else { return }
                await MainActor.run {
                    transcriptMessage.content = "Transcription cancelled."
                    bgTask?.status = .cancelled
                    self.finishTranscription(taskID: taskID)
                }
            } catch {
                guard let self else { return }
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    transcriptMessage.content = "⚠ Transcription failed: \(error.localizedDescription)"
                    bgTask?.status = .failed
                    bgTask?.errorMessage = error.localizedDescription
                    self.finishTranscription(taskID: taskID)
                }
            }
        }
    }

    private func finishTranscription(taskID: UUID) {
        activeTranscriptionCount = max(0, activeTranscriptionCount - 1)
        transcriptionTasks.removeValue(forKey: taskID)
        if activeTranscriptionCount == 0 {
            transcriptionProgress = 0
        }
        saveContext()
        refreshConversations()

        // Start next queued transcription if any
        let maxParallel = settingsManager.settings.transcription.maxParallelTranscriptions
        if !pendingTranscriptions.isEmpty && activeTranscriptionCount < maxParallel {
            let next = pendingTranscriptions.removeFirst()
            startTranscription(audioPath: next.audioPath, displayName: next.displayName, conversation: next.conversation, transcriptMessage: next.message)
        }
    }

    func stopTranscription() {
        for (_, task) in transcriptionTasks {
            task.cancel()
        }
        transcriptionTasks.removeAll()
    }

    private func formatTranscriptionResult(_ result: TranscriptionService.TranscriptionResult) -> String {
        let skipTimestamps = settingsManager.settings.transcription.skipTimestamps
        let duration = Self.formatDuration(result.elapsed)
        var text = "**Transcription** (\(result.language), \(duration))\n\n"
        text += skipTimestamps ? result.plainText : result.formattedTranscript
        return text
    }

    /// Formats seconds as `ss.s`, `mm:ss.s`, or `hh:mm:ss.s` depending on magnitude.
    private static func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let fraction = seconds - Double(totalSeconds)
        let tenths = Int(fraction * 10)

        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60

        if h > 0 {
            return String(format: "%d:%02d:%02d.%d", h, m, s, tenths)
        } else if m > 0 {
            return String(format: "%d:%02d.%d", m, s, tenths)
        } else {
            return String(format: "%d.%d", s, tenths)
        }
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
