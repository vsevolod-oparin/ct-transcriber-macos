import Foundation
import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

/// Wrapper that opts a value out of Sendable checking. Use only when you can guarantee
/// the wrapped value is accessed safely (e.g., only within MainActor.run blocks).
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

enum ConversationActivity {
    case streaming(task: Task<Void, Never>)
    case generatingTitle(task: Task<Void, Never>)
}

@Observable
@MainActor
final class ChatViewModel {
    /// Error prefixes — used to distinguish error source for retry logic.
    private static let llmErrorPrefix = "⚠ [LLM] "
    private static let transcriptionErrorPrefix = "⚠ [Transcription] "
    /// The conversation currently shown in the detail view. Set on click or Enter.
    var selectedConversationID: UUID?
    /// Conversations highlighted in the sidebar (for multi-select and delete). Arrow keys move this.
    var highlightedIDs: Set<UUID> = []
    /// Index of the keyboard cursor in the conversations array — the "anchor" for Shift+Arrow extension.
    var highlightCursor: Int = 0
    var messageText: String = ""
    var searchText: String = ""
    var conversations: [Conversation] = []

    /// Conversations filtered by search text.
    var filteredConversations: [Conversation] {
        guard !searchText.isEmpty else { return conversations }
        let query = searchText.lowercased()
        return conversations.filter { conversation in
            conversation.title.lowercased().contains(query) ||
            conversation.messages.contains { $0.content.lowercased().contains(query) }
        }
    }
    /// Per-conversation message drafts, keyed by conversation ID. In-memory only.
    private var drafts: [UUID: String] = [:]

    /// Called by the view when selected conversation changes.
    func conversationDidChange(from oldID: UUID?, to newID: UUID?) {
        if let oldID {
            drafts[oldID] = messageText
        }
        messageText = drafts[newID ?? UUID()] ?? ""
    }
    /// Incremented to force a ChatTableView re-evaluation after video aspect ratio changes.
    /// Video aspect ratios live in a static cache (not SwiftData), so @Query won't detect them.
    private(set) var videoUpdateTrigger: Int = 0
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

    private var activities: [UUID: ConversationActivity] = [:]

    /// True while any LLM is streaming a response.
    var isStreaming: Bool { activities.values.contains { if case .streaming = $0 { return true }; return false } }

    /// True if the currently selected conversation is streaming.
    var isStreamingCurrentConversation: Bool {
        guard let id = selectedConversationID else { return false }
        if case .streaming = activities[id] { return true }
        return false
    }
    /// Error message from the last LLM request, shown inline in the chat.
    var lastError: String?
    /// True while the LLM is generating a title for the selected conversation.
    var isGeneratingTitle: Bool {
        guard let id = selectedConversationID else { return false }
        if case .generatingTitle = activities[id] { return true }
        return false
    }

    /// Seek request: when a user clicks a timestamp in a transcript, this is set to
    /// (storedName, timeInSeconds) so the audio player can seek to that position.
    var seekRequest: (id: UUID, storedName: String, time: TimeInterval)?

    /// Number of active transcriptions.
    private(set) var activeTranscriptionCount: Int = 0
    /// Conversation IDs with active transcriptions.
    private(set) var transcribingConversationIDs: Set<UUID> = []
    /// True while any transcription is in progress.
    var isTranscribing: Bool { activeTranscriptionCount > 0 }
    /// True if the currently selected conversation has an active transcription.
    var isTranscribingCurrentConversation: Bool {
        guard let id = selectedConversationID else { return false }
        return transcribingConversationIDs.contains(id)
    }
    /// Progress of the most recent transcription (0.0–1.0).
    private(set) var transcriptionProgress: Double = 0

    private var modelContext: ModelContext
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingTranscriptions: [(audioPath: String, displayName: String, conversationID: UUID, messageID: UUID)] = []
    // Dependencies — constructor-injected for testability
    let settingsManager: SettingsManager
    let modelManager: ModelManager
    var taskManager: TaskManager?

    init(modelContext: ModelContext, settingsManager: SettingsManager, modelManager: ModelManager) {
        self.modelContext = modelContext
        self.settingsManager = settingsManager
        self.modelManager = modelManager
    }

    nonisolated deinit {
        AppLogger.debug("ChatViewModel deinit", category: "lifecycle")
    }

    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    func sortedMessages(for conversation: Conversation) -> [Message] {
        guard !conversation.isDeleted, conversation.modelContext != nil else { return [] }
        return conversation.messages
            .filter { !$0.isDeleted && $0.modelContext != nil }
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Conversation CRUD

    func createConversation() {
        let conversation = Conversation()
        modelContext.insert(conversation)
        saveContext()
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
    }

    func deleteConversation(_ conversation: Conversation) {
        drafts.removeValue(forKey: conversation.id)

        // Collect file paths to delete BEFORE mutating SwiftData
        // (avoids relationship traversal after delete, which blocks MainActor)
        var filesToDelete: [String] = []
        let messageIDs: Set<UUID>
        do {
            var ids = Set<UUID>()
            for message in conversation.messages {
                ids.insert(message.id)
                for attachment in message.attachments {
                    filesToDelete.append(attachment.storedName)
                    if let convertedName = attachment.convertedName {
                        filesToDelete.append(convertedName)
                    }
                }
            }
            messageIDs = ids
        }

        // Cancel and clean up any active transcription tasks for this conversation's messages
        cancelTranscriptionTasks(for: messageIDs)

        // Remove pending transcriptions for this conversation
        pendingTranscriptions.removeAll { $0.conversationID == conversation.id }

        // Cancel any streaming or title generation for this conversation
        if let activity = activities[conversation.id] {
            switch activity {
            case .streaming(let task), .generatingTitle(let task):
                task.cancel()
            }
            activities.removeValue(forKey: conversation.id)
        }

        // Delete the conversation from SwiftData
        let wasSelected = selectedConversationID == conversation.id
        modelContext.delete(conversation)
        saveContext()

        if wasSelected {
            selectedConversationID = conversations.first?.id
        }

        // Delete files AFTER SwiftData deletion, off MainActor (file I/O)
        Task.detached {
            for storedName in filesToDelete {
                FileStorage.delete(storedName: storedName)
            }
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
            transcribingConversationIDs.removeAll()
            transcriptionProgress = 0

            // Mark running transcription BackgroundTask objects as cancelled so they
            // don't linger in the task manager UI.  This is broad (all transcription
            // tasks) but consistent with the Swift Task cancellation above.
            if let taskManager {
                for bgTask in taskManager.tasks where bgTask.kind == .transcription && bgTask.status == .running {
                    taskManager.cancelTask(bgTask)
                }
            }
        }
    }

    // MARK: - Retry

    func retryMessage(_ message: Message, in conversation: Conversation) {
        guard !message.isDeleted, message.modelContext != nil,
              !conversation.isDeleted, conversation.modelContext != nil else { return }
        guard !isStreamingCurrentConversation && !isTranscribing else { return }

        let sorted = sortedMessages(for: conversation)

        if message.role == .assistant || message.role == .system {
            // Check if this was a failed transcription — look for audio/video attachment
            // in the message directly before this one
            if let myIdx = sorted.firstIndex(where: { $0.id == message.id }), myIdx > 0 {
                let prevMessage = sorted[myIdx - 1]
                let audioAttachment = prevMessage.attachments.first {
                    $0.kind == .audio || $0.kind == .video
                }

                if let att = audioAttachment, isTranscriptionMessage(message) {
                    // Re-trigger transcription: clear the failed message content, re-queue
                    let audioURL = FileStorage.url(for: att.storedName)
                    message.content = "⏳ Retrying transcription..."
                    message.lifecycle = .transcriptionQueued
                    saveContext()
                    startTranscription(
                        audioPath: audioURL.path,
                        displayName: att.originalName,
                        conversation: conversation,
                        transcriptMessage: message
                    )
                    return
                }
            }

            // Not a transcription — re-trigger LLM response
            conversation.messages.removeAll { $0.id == message.id }
            modelContext.delete(message)
            saveContext()
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

            // Re-create the user message and trigger LLM
            let newMessage = Message(role: .user, content: message.content)
            conversation.messages.append(newMessage)
            conversation.updatedAt = Date()
            saveContext()
            requestLLMResponse(for: conversation)
        }
    }

    private func isTranscriptionMessage(_ message: Message) -> Bool {
        switch message.lifecycle {
        case .transcribing, .transcriptionQueued, .errorTranscription, .cancelled:
            return true
        case .complete, nil:
            return message.content.hasPrefix("**Transcription**")
        default:
            return false
        }
    }

    // MARK: - Send Message + LLM Streaming

    func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let conversation = selectedConversation else { return }
        // Only block if THIS conversation is streaming, not others
        guard !isStreamingCurrentConversation else { return }

        let userMessage = Message(role: .user, content: text)
        conversation.messages.append(userMessage)
        conversation.updatedAt = Date()
        autoTitleIfNeeded(conversation, firstMessageText: text)
        messageText = ""
        lastError = nil
        saveContext()

        requestLLMResponse(for: conversation)
    }

    func stopStreaming() {
        guard let convoID = selectedConversationID,
              case .streaming(let task) = activities[convoID] else { return }
        task.cancel()
        activities.removeValue(forKey: convoID)
        if let conversation = selectedConversation,
           let last = sortedMessages(for: conversation).last,
           last.role == .assistant, last.lifecycle == .streaming {
            last.lifecycle = .complete
        }
        saveContext()
    }

    private func requestLLMResponse(for conversation: Conversation) {
        guard let provider = settingsManager.activeProvider else { return }

        let apiKey = provider.apiKey
        guard !apiKey.isEmpty else {
            let errorMessage = Message(role: .assistant, content: "\(Self.llmErrorPrefix)\(LLMError.noAPIKey.localizedDescription)")
            errorMessage.lifecycle = .errorLLM
            conversation.messages.append(errorMessage)
            saveContext()
            return
        }

        let service = LLMServiceFactory.service(for: provider)
        let messages = buildMessageDTOs(for: conversation)

        let convoID = conversation.id

        // Create a placeholder assistant message
        let assistantMessage = Message(role: .assistant, content: "")
        assistantMessage.lifecycle = .streaming
        conversation.messages.append(assistantMessage)
        saveContext()

        // Each conversation gets its own streaming Task — fully isolated
        let task = Task { [weak self] in
            var accumulatedText = ""
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
                var pendingTokens = ""
                let updateThreshold = 50 // characters before flushing to UI

                for try await token in stream {
                    guard let _ = self, !Task.isCancelled else { break }
                    pendingTokens += token
                    if pendingTokens.count >= updateThreshold {
                        accumulatedText += pendingTokens
                        pendingTokens = ""
                        await MainActor.run {
                            assistantMessage.content = accumulatedText
                        }
                    }
                }
                // Flush remaining tokens
                if !pendingTokens.isEmpty {
                    accumulatedText += pendingTokens
                    await MainActor.run {
                        assistantMessage.content = accumulatedText
                    }
                }

                guard let self else { return }
                await MainActor.run {
                    assistantMessage.lifecycle = .complete
                    self.finalizeStreaming(for: convoID)
                    self.autoNameIfFirstResponse(conversation, provider: provider)
                }
            } catch is CancellationError {
                guard let self else { return }
                await MainActor.run {
                    assistantMessage.lifecycle = .complete
                    self.finalizeStreaming(for: convoID)
                }
            } catch let error as LLMError where error.isCancelled {
                guard let self else { return }
                await MainActor.run {
                    assistantMessage.lifecycle = .complete
                    self.finalizeStreaming(for: convoID)
                }
            } catch {
                guard let self else { return }
                await MainActor.run {
                    let partial = assistantMessage.content.isEmpty ? "" : assistantMessage.content + "\n\n"
                    assistantMessage.content = "\(partial)\(Self.llmErrorPrefix)\(error.localizedDescription)"
                    assistantMessage.lifecycle = .errorLLM
                    self.finalizeStreaming(for: convoID)
                }
            }
        }
        activities[convoID] = .streaming(task: task)
    }

    private func finalizeStreaming(for conversationID: UUID? = nil) {
        if let id = conversationID {
            activities.removeValue(forKey: id)
        } else {
            activities = activities.filter { _, v in
                if case .streaming = v { return false }
                return true
            }
        }
        saveContext()
    }

    private func buildMessageDTOs(for conversation: Conversation) -> [ChatMessageDTO] {
        var dtos: [ChatMessageDTO] = []

        // Prepend system prompt from active provider if set
        if let prompt = settingsManager.activeProvider?.systemPrompt, !prompt.isEmpty {
            dtos.append(ChatMessageDTO(role: "system", content: prompt))
        }

        dtos += sortedMessages(for: conversation)
            .compactMap { message in
                guard !message.content.isEmpty else { return nil }
                return ChatMessageDTO(role: message.role.rawValue, content: message.content)
            }

        return dtos
    }

    // MARK: - Auto-naming

    private static let autoTitleMaxLength = 50
    private static let autoNamePrompt = "Give a short title (max 6 words) summarizing the ENTIRE conversation above, not just the last message. Consider all messages equally. Use the same language as the conversation content. Reply with ONLY the title, no quotes or punctuation."

    private func autoTitleIfNeeded(_ conversation: Conversation, firstMessageText: String) {
        let isFirstMessage = conversation.messages.count == 1
        let hasDefaultTitle = conversation.title == "New Conversation"
        guard isFirstMessage && hasDefaultTitle else { return }

        let truncated = String(firstMessageText.prefix(Self.autoTitleMaxLength))
        conversation.title = truncated.count < firstMessageText.count
            ? "\(truncated)..."
            : truncated
    }

    /// Auto-name after first LLM response if title is still default.
    private func autoNameIfFirstResponse(_ conversation: Conversation, provider: ProviderConfig? = nil) {
        guard conversation.title == "New Conversation" || conversation.title.hasSuffix("...") else { return }
        autoNameConversation(conversation, using: provider, silent: true)
    }

    /// Ask the LLM to generate a title from the conversation content.
    /// Public: called from the sparkle button. Also called internally after first assistant response.
    func autoNameConversation(_ conversation: Conversation, using overrideProvider: ProviderConfig? = nil, silent: Bool = false) {
        guard let provider = overrideProvider ?? settingsManager.activeProvider else {
            AppLogger.debug("Auto-name skipped: no active provider", category: "auto-title")
            if !silent { lastError = "Auto-title: no LLM provider configured. Open Settings (⌘,)." }
            return
        }

        // Need at least one message to generate a title from
        guard !conversation.messages.isEmpty else { return }

        let apiKey = provider.apiKey
        guard !apiKey.isEmpty else {
            AppLogger.debug("Auto-name skipped: no API key for \(provider.name)", category: "auto-title")
            if !silent { lastError = "Auto-title: no API key for \(provider.name). Open Settings (⌘,)." }
            return
        }

        let service = LLMServiceFactory.service(for: provider)

        let maxCharsPerMessage = 500
        var namingMessages = buildMessageDTOs(for: conversation).map { dto in
            if dto.content.count > maxCharsPerMessage {
                let truncated = String(dto.content.prefix(maxCharsPerMessage))
                return ChatMessageDTO(role: dto.role, content: truncated + "…[truncated]")
            }
            return dto
        }
        namingMessages.append(ChatMessageDTO(role: "user", content: Self.autoNamePrompt))

        AppLogger.debug("Auto-naming with \(namingMessages.count - 1) messages via \(provider.name)", category: "auto-title")

        let convoID = conversation.id
        let titleTask = Task { [weak self] in
            guard let self else { return }
            var title = ""
            let stream = service.streamCompletion(
                messages: namingMessages,
                model: provider.defaultModel,
                temperature: 0.3,
                maxTokens: 4096,
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
                AppLogger.error("Auto-name failed: \(error.localizedDescription)", category: "auto-title")
                self.activities.removeValue(forKey: convoID)
                if !silent {
                    self.lastError = "Auto-title failed: \(error.localizedDescription)"
                }
                return
            }

            let quoteSet = CharacterSet(charactersIn: "\"")
            let firstLine = title.components(separatedBy: .newlines)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? title
            let cleaned = firstLine.trimmingCharacters(in: .whitespacesAndNewlines.union(quoteSet))
            self.activities.removeValue(forKey: convoID)
            guard !cleaned.isEmpty else {
                AppLogger.debug("Auto-name returned empty title", category: "auto-title")
                return
            }
            AppLogger.debug("Auto-named: \(cleaned)", category: "auto-title")
            conversation.title = String(cleaned.prefix(Self.autoTitleMaxLength))
            conversation.updatedAt = Date()
            self.saveContext()
        }
        activities[convoID] = .generatingTitle(task: titleTask)
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
        selectedConversationID = conversation.id

        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            attachFile(from: url, to: conversation)
        }
    }

    // MARK: - File Attachment

    func attachFile(from url: URL, to conversation: Conversation) {
        let kind = FileStorage.attachmentKind(for: url)
        let originalName = url.lastPathComponent
        let conversationID = conversation.id

        Task.detached {
            guard let storedName = try? FileStorage.copyToStorage(from: url) else { return }

            await MainActor.run { [self] in
                guard let conversation = self.conversations.first(where: { $0.id == conversationID }) else { return }
                let attachment = Attachment(kind: kind, storedName: storedName, originalName: originalName)

                let message = Message(role: .user, content: "Attached \(kind.rawValue): \(originalName)")
                message.attachments.append(attachment)
                conversation.messages.append(message)
                conversation.updatedAt = Date()
                self.saveContext()

                self.postAttachActions(kind: kind, storedName: storedName, originalName: originalName,
                                       attachment: attachment, conversation: conversation,
                                       skipSaveRefresh: true)
            }
        }
    }

    private func postAttachActions(kind: AttachmentKind, storedName: String, originalName: String,
                                    attachment: Attachment, conversation: Conversation,
                                    skipSaveRefresh: Bool = false) {
        // Pre-compute video aspect ratio on background thread (avoids blocking scroll)
        if kind == .video {
            let videoURL = FileStorage.url(for: storedName)
            Task.detached(priority: .utility) {
                ChatTableView.Coordinator.precomputeVideoAspectRatio(url: videoURL)
                await MainActor.run { [weak self] in
                    self?.videoUpdateTrigger += 1
                }
            }
        }

        // Auto-transcribe audio and video files
        if kind == .audio || kind == .video {
            let audioURL = FileStorage.url(for: storedName)
            transcribeAudio(at: audioURL.path, originalName: originalName, in: conversation, skipSaveRefresh: skipSaveRefresh)
        }

        // Convert unsupported video formats (WebM, MKV) to MP4 for playback
        if kind == .video && VideoConverter.needsConversion(originalName) {
            Task {
                let transSettings = settingsManager.settings.transcription
                if let mp4Name = await VideoConverter.convertToMP4(
                    storedName: storedName, settings: transSettings) {
                    // Precompute aspect ratio from the converted MP4 BEFORE updating UI.
                    // The original file (WebM/MKV) can't be read by AVAsset, so
                    // precomputeVideoAspectRatio fails for it. Computing from the MP4
                    // ensures the first render after conversion uses the correct ratio.
                    let mp4URL = FileStorage.url(for: mp4Name)
                    ChatTableView.Coordinator.precomputeVideoAspectRatio(url: mp4URL)

                    await MainActor.run { [self] in
                        attachment.convertedName = mp4Name
                        saveContext()
                    }
                }
            }
        }
    }

    // MARK: - Transcription

    func transcribeAudio(at audioPath: String, originalName: String? = nil, in conversation: Conversation, skipSaveRefresh: Bool = false) {
        // Create placeholder message immediately so it appears right after the audio
        let displayName = originalName ?? (audioPath as NSString).lastPathComponent
        let transcriptMessage = Message(role: .assistant, content: "⏳ Queued: \(displayName)")
        transcriptMessage.lifecycle = .transcriptionQueued
        conversation.messages.append(transcriptMessage)
        if !skipSaveRefresh {
            saveContext()
        }

        // Queue if at capacity
        if activeTranscriptionCount >= settingsManager.settings.transcription.maxParallelTranscriptions {
            pendingTranscriptions.append((audioPath: audioPath, displayName: displayName, conversationID: conversation.id, messageID: transcriptMessage.id))
            AppLogger.info("Transcription queued (\(pendingTranscriptions.count) pending)", category: "transcription")
            return
        }

        startTranscription(audioPath: audioPath, displayName: displayName, conversation: conversation, transcriptMessage: transcriptMessage)
    }

    private func startTranscription(audioPath: String, displayName: String, conversation: Conversation, transcriptMessage: Message) {
        let transSettings = settingsManager.settings.transcription

        let selectedID = transSettings.selectedModelID
        guard let modelPath = modelManager.modelPath(for: selectedID) else {
            transcriptMessage.content = "\(Self.transcriptionErrorPrefix)\(TranscriptionError.modelNotDownloaded.localizedDescription)"
            transcriptMessage.lifecycle = .errorTranscription
            saveContext()
            return
        }

        activeTranscriptionCount += 1
        transcribingConversationIDs.insert(conversation.id)
        transcriptionProgress = 0
        transcriptMessage.content = "Transcribing..."
        transcriptMessage.lifecycle = .transcribing

        let bgTask = taskManager?.createTask(kind: .transcription, title: displayName, conversationTitle: conversation.title)
        let taskID = UUID()
        let convoID = conversation.id

        // These SwiftData model objects are only accessed inside MainActor.run blocks within
        // the detached task, so crossing the isolation boundary is safe.
        let wrappedMessage = UncheckedSendableBox(value: transcriptMessage)
        let wrappedBgTask = UncheckedSendableBox(value: bgTask)

        let task = Task.detached { [weak self] in
            // Check audio track off MainActor — AVAsset.tracks is synchronous I/O
            let audioURL = URL(fileURLWithPath: audioPath)
            let ext = audioURL.pathExtension.lowercased()
            let avUnsupportedFormats: Set<String> = ["webm", "mkv", "flv", "wmv", "ogg", "opus"]
            if !avUnsupportedFormats.contains(ext) {
                let asset = AVAsset(url: audioURL)
                if asset.tracks(withMediaType: .audio).isEmpty {
                    await MainActor.run { [weak self] in
                        wrappedMessage.value.content = "\(ChatViewModel.transcriptionErrorPrefix)No audio track found in this file. Cannot transcribe."
                        wrappedMessage.value.lifecycle = .errorTranscription
                        self?.finishTranscription(taskID: taskID, conversationID: convoID)
                    }
                    return
                }
            }

            let stream = TranscriptionService.transcribe(
                audioPath: audioPath,
                modelPath: modelPath,
                settings: transSettings
            )

            do {
                var finalResult: TranscriptionService.TranscriptionResult?
                var lastUIUpdate = Date.distantPast
                let uiUpdateInterval: TimeInterval = 0.3

                for try await progress in stream {
                    guard !Task.isCancelled else { break }

                    switch progress {
                    case .started(let language, let duration):
                        await MainActor.run {
                            wrappedMessage.value.content = "Transcribing... (detected: \(language), \(ChatViewModel.formatDuration(duration)))"
                            wrappedBgTask.value?.status = .running
                        }
                    case .segment(_, let text, let prog):
                        let now = Date()
                        guard now.timeIntervalSince(lastUIUpdate) >= uiUpdateInterval else { continue }
                        lastUIUpdate = now
                        await MainActor.run { [weak self] in
                            self?.transcriptionProgress = prog
                            wrappedBgTask.value?.progress = prog
                            wrappedMessage.value.content = "Transcribing (\(Int(prog * 100))%)...\n\n\(text)"
                        }
                    case .completed(let res):
                        finalResult = res
                    case .error(let msg):
                        await MainActor.run { [weak self] in
                            self?.lastError = msg
                        }
                    }
                }

                let completedResult = finalResult
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let completedResult {
                        wrappedMessage.value.content = self.formatTranscriptionResult(completedResult)
                        wrappedMessage.value.lifecycle = .complete
                        wrappedBgTask.value?.status = .completed
                        wrappedBgTask.value?.progress = 1.0
                    }
                    self.finishTranscription(taskID: taskID, conversationID: convoID)
                }
            } catch let error as TranscriptionError where error.isCancelled {
                await MainActor.run { [weak self] in
                    wrappedMessage.value.content = "Transcription cancelled."
                    wrappedMessage.value.lifecycle = .cancelled
                    wrappedBgTask.value?.status = .cancelled
                    self?.finishTranscription(taskID: taskID, conversationID: convoID)
                }
            } catch {
                let errorDesc = error.localizedDescription
                await MainActor.run { [weak self] in
                    self?.lastError = errorDesc
                    wrappedMessage.value.content = "\(ChatViewModel.transcriptionErrorPrefix)\(errorDesc)"
                    wrappedMessage.value.lifecycle = .errorTranscription
                    wrappedBgTask.value?.status = .failed
                    wrappedBgTask.value?.errorMessage = errorDesc
                    self?.finishTranscription(taskID: taskID, conversationID: convoID)
                }
            }
        }
        transcriptionTasks[taskID] = task
    }

    private func finishTranscription(taskID: UUID, conversationID: UUID) {
        activeTranscriptionCount = max(0, activeTranscriptionCount - 1)
        transcriptionTasks.removeValue(forKey: taskID)
        transcribingConversationIDs.remove(conversationID)
        if activeTranscriptionCount == 0 {
            transcriptionProgress = 0
        }
        saveContext()

        // Yield the run loop before starting next transcription — lets input events process
        let maxParallel = settingsManager.settings.transcription.maxParallelTranscriptions
        if !pendingTranscriptions.isEmpty && activeTranscriptionCount < maxParallel {
            DispatchQueue.main.async { [self] in
                while !pendingTranscriptions.isEmpty && activeTranscriptionCount < maxParallel {
                    let next = pendingTranscriptions.removeFirst()
                    guard let conversation = conversations.first(where: { $0.id == next.conversationID }),
                          let message = conversation.messages.first(where: { $0.id == next.messageID }) else {
                        continue
                    }
                    startTranscription(audioPath: next.audioPath, displayName: next.displayName, conversation: conversation, transcriptMessage: message)
                    break
                }
            }
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

    // MARK: - Conversation Export / Import

    func exportConversationJSON(_ conversation: Conversation) {
        guard let data = try? ConversationExporter.exportJSON(conversation: conversation) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let safeName = conversation.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeName).json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
            } catch {
                lastError = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func exportConversationMarkdown(_ conversation: Conversation) {
        let md = ConversationExporter.exportMarkdown(conversation: conversation)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let safeName = conversation.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeName).md"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try md.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                lastError = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func exportConversationPDF(_ conversation: Conversation) {
        guard let data = ConversationExporter.exportPDF(conversation: conversation) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let safeName = conversation.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeName).pdf"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
            } catch {
                lastError = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func importConversation() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                let conversation = try ConversationExporter.importJSON(data: data, into: modelContext)
                selectedConversationID = conversation.id
            } catch {
                lastError = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    func exportAllConversations() {
        guard !conversations.isEmpty else { return }
        do {
            let data = try ConversationExporter.exportBulkZIP(conversations: conversations)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "zip") ?? .data]
            panel.nameFieldStringValue = "conversations-export.zip"
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
            }
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private func saveContext() {
        do {
            try modelContext.save()
        } catch {
            AppLogger.error("SwiftData save failed: \(error)", category: "data")
        }
    }

    func refreshAfterVideoChange() {
        videoUpdateTrigger += 1
    }
}
