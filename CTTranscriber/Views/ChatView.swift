import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct ChatView: View {
    let conversation: Conversation
    @Bindable var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool
    @State private var scrollToTopTrigger = 0
    @State private var scrollToBottomTrigger = 0
    @State private var isRenamingTitle = false
    @State private var renameTitleText = ""
    var body: some View {
        VStack(spacing: 0) {
            ChatTableView(messages: viewModel.sortedMessages(for: conversation),
                          isStreaming: viewModel.isStreaming,
                          onRetry: { message in viewModel.retryMessage(message, in: conversation) },
                          onDropFiles: { urls in
                              for url in urls {
                                  viewModel.attachFile(from: url, to: conversation)
                              }
                          },
                          seekRequest: $viewModel.seekRequest,
                          conversationID: conversation.id,
                          scrollToTopTrigger: scrollToTopTrigger,
                          scrollToBottomTrigger: scrollToBottomTrigger)

            if viewModel.isTranscribing {
                TranscriptionProgressBar(
                    progress: viewModel.transcriptionProgress,
                    onStop: { viewModel.stopTranscription() }
                )
            }

            if let error = viewModel.lastError {
                ErrorBanner(message: error) {
                    viewModel.lastError = nil
                }
            }

            Divider()

            ChatInputBar(viewModel: viewModel, conversation: conversation, isInputFocused: $isInputFocused)
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if isRenamingTitle {
                    TitleRenameField(
                        text: $renameTitleText,
                        onCommit: {
                            let trimmed = renameTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                viewModel.renameConversation(conversation, to: trimmed)
                            }
                            isRenamingTitle = false
                        },
                        onCancel: {
                            isRenamingTitle = false
                        }
                    )
                    .frame(width: 250)
                } else {
                    Text(conversation.title)
                        .font(.headline)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            renameTitleText = conversation.title
                            isRenamingTitle = true
                        }
                }
            }
        }
        .onChange(of: viewModel.focusCounter) { _, _ in
            isInputFocused = true
        }
        .onKeyPress(keys: [.upArrow], phases: .down) { keyPress in
            if keyPress.modifiers.contains(.command) {
                scrollToTopTrigger += 1
                return .handled
            }
            return .ignored
        }
        .onKeyPress(keys: [.downArrow], phases: .down) { keyPress in
            if keyPress.modifiers.contains(.command) {
                scrollToBottomTrigger += 1
                return .handled
            }
            return .ignored
        }
    }

}

// MARK: - Transcription Progress

private struct TranscriptionProgressBar: View {
    let progress: Double
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(Color.accentColor)
            Text("Transcribing...")
                .font(.caption)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            Text("\(Int(progress * 100))%")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 35, alignment: .trailing)
            Button(action: onStop) {
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Stop transcription")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Error Banner

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .lineLimit(5)
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Copy error message")
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Chat Table View (NSTableView-backed message list)

/// Replaces the SwiftUI ScrollView+LazyVStack with NSTableView for:
/// - Reliable scroll-to-bottom (no LazyVStack height estimation issues)
/// - ID-based scroll preservation on expand/collapse
/// - Targeted row updates during streaming (no full list refresh)
/// - Cell reuse for memory efficiency
struct ChatTableView: NSViewRepresentable {
    let messages: [Message]
    let isStreaming: Bool
    let onRetry: (Message) -> Void
    let onDropFiles: ([URL]) -> Void
    @Binding var seekRequest: (storedName: String, time: TimeInterval)?
    let conversationID: UUID?
    let scrollToTopTrigger: Int
    let scrollToBottomTrigger: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let tableView = ChatNSTableView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 12)
        tableView.rowSizeStyle = .custom

        // Performance: disable automatic layer redraws (from TelegramSwift research)
        tableView.layerContentsRedrawPolicy = .never

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        // Register as drag-and-drop target for files
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        context.coordinator.tableView = tableView
        context.coordinator.scrollView = scrollView
        context.coordinator.onDropFiles = onDropFiles
        context.coordinator.seekRequest = $seekRequest

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let oldMessages = coordinator.messages
        let oldStreaming = coordinator.isStreaming
        let oldConversationID = coordinator.conversationID

        coordinator.onRetry = onRetry
        coordinator.onDropFiles = onDropFiles
        coordinator.seekRequest = $seekRequest
        coordinator.isStreaming = isStreaming

        guard let tableView = coordinator.tableView else { return }

        // Conversation switch — full reload + scroll to bottom
        if conversationID != oldConversationID {
            coordinator.conversationID = conversationID
            coordinator.messages = messages
            coordinator.heightCache.removeAll()
            coordinator.expandedMessages.removeAll()
            coordinator.contentLengthSnapshot = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0.content.count) })
            tableView.reloadData()
            DispatchQueue.main.async {
                coordinator.scrollToBottom(animated: false)
            }
            return
        }

        let oldIDs = oldMessages.map(\.id)
        let newIDs = messages.map(\.id)

        if oldIDs == newIDs {
            // Same messages — find which rows have content changes
            coordinator.messages = messages

            // Detect content changes using a snapshot of content lengths.
            // SwiftData models are reference types — oldMessages and messages
            // share the same objects, so we can't compare them directly.
            var changedRows = IndexSet()
            for i in messages.indices {
                let msg = messages[i]
                let currentLen = msg.content.count
                let snapshotLen = coordinator.contentLengthSnapshot[msg.id]
                if snapshotLen == nil || snapshotLen != currentLen {
                    changedRows.insert(i)
                }
            }

            if isStreaming, let lastRow = messages.indices.last {
                changedRows.insert(lastRow)
            }

            // Update snapshot
            for msg in messages {
                coordinator.contentLengthSnapshot[msg.id] = msg.content.count
            }

            if !changedRows.isEmpty {
                for row in changedRows {
                    coordinator.heightCache.removeValue(forKey: messages[row].id)
                }
                tableView.noteHeightOfRows(withIndexesChanged: changedRows)
                tableView.reloadData(forRowIndexes: changedRows,
                                     columnIndexes: IndexSet(integer: 0))

                if isStreaming {
                    coordinator.scrollToBottomThrottled()
                }
            }

            if oldStreaming && !isStreaming {
                coordinator.scrollToBottom(animated: true)
            }
        } else {
            // Messages added or removed
            coordinator.messages = messages

            let oldSet = Set(oldIDs)
            let newSet = Set(newIDs)

            // Clean up caches for removed messages
            for id in oldSet.subtracting(newSet) {
                coordinator.heightCache.removeValue(forKey: id)
                coordinator.expandedMessages.remove(id)
            }

            // Fast path: messages only appended (most common — new message or transcription placeholder)
            if newIDs.count > oldIDs.count && newIDs.starts(with: oldIDs) {
                let insertRange = oldIDs.count..<newIDs.count
                tableView.insertRows(at: IndexSet(insertRange), withAnimation: .slideDown)
                DispatchQueue.main.async {
                    coordinator.scrollToBottom(animated: true)
                }
            } else {
                // General case: deletions or reorders — full reload
                tableView.reloadData()
                if newIDs.count >= oldIDs.count {
                    DispatchQueue.main.async {
                        coordinator.scrollToBottom(animated: false)
                    }
                }
            }
        }

        // Handle scroll triggers from Cmd+Up / Cmd+Down
        if scrollToTopTrigger != coordinator.lastTopTrigger {
            coordinator.lastTopTrigger = scrollToTopTrigger
            coordinator.scrollToTop()
        }
        if scrollToBottomTrigger != coordinator.lastBottomTrigger {
            coordinator.lastBottomTrigger = scrollToBottomTrigger
            coordinator.scrollToBottom(animated: true)
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var messages: [Message] = []
        var isStreaming: Bool = false
        var onRetry: (Message) -> Void = { _ in }
        var onDropFiles: ([URL]) -> Void = { _ in }
        /// Shared seek request state — passed through to AudioPlayerView bindings.
        var seekRequest: Binding<(storedName: String, time: TimeInterval)?>?
        var conversationID: UUID?

        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?

        /// Cached row heights keyed by message ID. Invalidated on width change or content change.
        var heightCache: [UUID: CGFloat] = [:]
        /// Snapshot of content lengths per message ID — used to detect in-place content changes.
        /// Needed because SwiftData Message objects are reference types: comparing old vs new
        /// messages gives the same object, so content appears unchanged.
        var contentLengthSnapshot: [UUID: Int] = [:]
        /// Messages the user has expanded (for long/collapsible messages).
        var expandedMessages: Set<UUID> = []

        var lastTableWidth: CGFloat = 0
        var lastTopTrigger: Int = 0
        var lastBottomTrigger: Int = 0

        /// Throttle for scroll-during-streaming
        private var lastStreamingScrollTime: Date = .distantPast
        private static let streamingScrollInterval: TimeInterval = 0.2

        /// Shared sizing view for height measurement — avoids allocating per row.
        private var sizingHostingView: NSHostingView<AnyView>?

        // MARK: - DataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            messages.count
        }

        // MARK: - Drag and Drop

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            // Accept file drops anywhere on the table
            if info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) {
                return .copy
            }
            return []
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
                .urlReadingFileURLsOnly: true
            ]) as? [URL], !urls.isEmpty else {
                return false
            }
            AppLogger.info("Table drop: \(urls.count) file(s)", category: "drop")
            onDropFiles(urls)
            return true
        }

        // MARK: - Delegate (cell creation)

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < messages.count else { return nil }
            let message = messages[row]
            let isStreamingThis = isStreaming && row == messages.count - 1 && message.role == .assistant
            let isExpanded = expandedMessages.contains(message.id)

            let seekBinding = seekRequest ?? .constant(nil)
            let bubble = MessageBubble(
                message: message,
                isStreamingThis: isStreamingThis,
                isExpanded: isExpanded,
                onRetry: { [weak self] in self?.onRetry(message) },
                onCollapseToggle: { [weak self] in
                    self?.toggleExpanded(for: message.id, row: row)
                },
                seekRequest: seekBinding
            )
            .padding(.horizontal, 16)

            let cell = NSHostingView(rootView: bubble)
            // Pre-set frame width to match table column so the cell doesn't
            // briefly render at a narrow intrinsic width before layout.
            let columnWidth = tableView.tableColumns.first?.width ?? tableView.bounds.width
            if columnWidth > 0 {
                cell.frame.size.width = columnWidth
            }
            return cell
        }

        // MARK: - Delegate (row heights)

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < messages.count else { return 44 }
            let message = messages[row]

            // Use column width (more reliable than bounds during initial layout)
            let currentWidth = tableView.tableColumns.first?.width ?? tableView.bounds.width
            if currentWidth > 0 && abs(currentWidth - lastTableWidth) > 1 {
                heightCache.removeAll()
                lastTableWidth = currentWidth
            }

            // Don't cache if width hasn't been established yet
            let widthEstablished = currentWidth > 300

            // Don't cache streaming row — it changes every token
            let isStreamingThis = isStreaming && row == messages.count - 1 && message.role == .assistant
            if !isStreamingThis && widthEstablished, let cached = heightCache[message.id] {
                return cached
            }

            // Measure height via a temporary NSHostingView
            let isExpanded = expandedMessages.contains(message.id)

            let bubble = MessageBubble(
                message: message,
                isStreamingThis: isStreamingThis,
                isExpanded: isExpanded,
                onRetry: {},
                onCollapseToggle: {},
                seekRequest: .constant(nil)
            )
            .padding(.horizontal, 16)

            let measuringView = NSHostingView(rootView: bubble)
            let targetWidth = max(currentWidth, 200)

            // For collapsed long messages, ensure minimum height shows the preview lines.
            // The NSHostingView measurement can underestimate when the Text view
            // hasn't computed its multi-line layout at the constrained width.
            let isCollapsedLong = !isExpanded && message.content.count > 200 && MessageAnalysis(content: message.content).isLong

            // For large expanded messages, compute text height directly via NSTextStorage
            // because nested NSViewRepresentable (LargeTextView) inside a measuring
            // NSHostingView doesn't report correct height.
            let useLargeText = isExpanded && message.content.count > largeTextThreshold
            let fittingHeight: CGFloat

            if useLargeText {
                // Measure text height directly using the text layout system
                let bubbleHPadding: CGFloat = 12 * 2    // .padding(.horizontal, 12)
                let bubbleVPadding: CGFloat = 8 * 2     // .padding(.vertical, 8)
                let outerHPadding: CGFloat = 16 * 2     // .padding(.horizontal, 16)
                let spacerWidth: CGFloat = 60 + 4 + 24  // Spacer(minLength:60) + spacing + copy button
                let textWidth = targetWidth - outerHPadding - bubbleHPadding - spacerWidth

                let textHeight = Self.measureTextHeight(
                    message.content, width: max(textWidth, 100))

                // bubble content + padding + timestamp row + attachments
                let attachmentHeight: CGFloat = message.attachments.isEmpty ? 0 : CGFloat(message.attachments.count) * 30
                let timestampHeight: CGFloat = 20
                let collapseButtonHeight: CGFloat = 24
                fittingHeight = textHeight + bubbleVPadding + timestampHeight + attachmentHeight + collapseButtonHeight
            } else {
                // Normal messages: use Auto Layout measurement
                measuringView.translatesAutoresizingMaskIntoConstraints = false
                let widthConstraint = measuringView.widthAnchor.constraint(equalToConstant: targetWidth)
                widthConstraint.isActive = true
                measuringView.layoutSubtreeIfNeeded()
                fittingHeight = measuringView.fittingSize.height
                widthConstraint.isActive = false
            }

            var height = max(fittingHeight, 30)

            // For collapsed long messages, ensure minimum height to show preview lines.
            // NSHostingView measurement can underestimate multi-line SwiftUI Text.
            if isCollapsedLong {
                let analysis = MessageAnalysis(content: message.content)
                let previewText = analysis.collapsedPreview
                let bubbleHPadding: CGFloat = 12 * 2
                let outerHPadding: CGFloat = 16 * 2
                let spacerWidth: CGFloat = 60 + 4 + 24
                let textWidth = targetWidth - outerHPadding - bubbleHPadding - spacerWidth
                let previewHeight = Self.measureTextHeight(previewText, width: max(textWidth, 100))
                let bubbleVPadding: CGFloat = 8 * 2
                let timestampHeight: CGFloat = 20
                let collapseButtonHeight: CGFloat = 24
                let attachmentHeight: CGFloat = message.attachments.isEmpty ? 0 : CGFloat(message.attachments.count) * 30
                let minHeight = previewHeight + bubbleVPadding + timestampHeight + collapseButtonHeight + attachmentHeight
                height = max(height, minHeight)
            }

            if !isStreamingThis {
                heightCache[message.id] = height
            }

            return height
        }

        // MARK: - Text Height Measurement

        /// Measures the rendered height of a text string at a given width using NSTextStorage.
        /// More reliable than NSHostingView measurement for large text blocks.
        static func measureTextHeight(_ text: String, width: CGFloat) -> CGFloat {
            let textStorage = NSTextStorage(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ])
            let textContainer = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
            textContainer.lineFragmentPadding = 0
            let layoutManager = NSLayoutManager()
            layoutManager.addTextContainer(textContainer)
            textStorage.addLayoutManager(layoutManager)
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            return ceil(usedRect.height)
        }

        // MARK: - Expand / Collapse

        func toggleExpanded(for messageID: UUID, row: Int) {
            if expandedMessages.contains(messageID) {
                expandedMessages.remove(messageID)
            } else {
                expandedMessages.insert(messageID)
            }

            heightCache.removeValue(forKey: messageID)

            guard let tableView else { return }

            // Update the existing cell's content in place (no reload = no flash).
            // Find the current cell and swap its rootView with updated expand state.
            if let existingCell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) {
                let message = messages[row]
                let isStreamingThis = isStreaming && row == messages.count - 1 && message.role == .assistant
                let isExpanded = expandedMessages.contains(message.id)

                let seekBinding = self.seekRequest ?? .constant(nil)
                let updatedBubble = MessageBubble(
                    message: message,
                    isStreamingThis: isStreamingThis,
                    isExpanded: isExpanded,
                    onRetry: { [weak self] in self?.onRetry(message) },
                    onCollapseToggle: { [weak self] in
                        self?.toggleExpanded(for: message.id, row: row)
                    },
                    seekRequest: seekBinding
                )
                .padding(.horizontal, 16)

                // Replace the cell's content with a new hosting view
                // (cheaper than reloadData which destroys + recreates)
                let newHosting = NSHostingView(rootView: updatedBubble)
                newHosting.frame = existingCell.bounds
                existingCell.subviews.forEach { $0.removeFromSuperview() }
                newHosting.autoresizingMask = [.width, .height]
                existingCell.addSubview(newHosting)
            }

            // Save the scroll position BEFORE the height change so we can restore it.
            // This keeps the viewport exactly where it was — the expansion happens
            // "below" the current view, so the user sees no scroll jump.
            let savedOrigin = scrollView?.contentView.bounds.origin ?? .zero

            // Animate only the height change — the cell content is already updated
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            }

            // Restore exact scroll position — no visible jump
            scrollView?.contentView.setBoundsOrigin(savedOrigin)
            scrollView?.reflectScrolledClipView(scrollView!.contentView)
        }

        // MARK: - Scrolling

        func scrollToBottom(animated: Bool) {
            guard let tableView, !messages.isEmpty else { return }
            let lastRow = messages.count - 1
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.allowsImplicitAnimation = true
                    tableView.scrollRowToVisible(lastRow)
                }
            } else {
                tableView.scrollRowToVisible(lastRow)
            }
        }

        func scrollToTop() {
            guard let tableView, !messages.isEmpty else { return }
            tableView.scrollRowToVisible(0)
        }

        /// Throttled scroll during streaming — every 200ms to avoid per-token overhead.
        func scrollToBottomThrottled() {
            let now = Date()
            if now.timeIntervalSince(lastStreamingScrollTime) >= Self.streamingScrollInterval {
                lastStreamingScrollTime = now
                scrollToBottom(animated: false)
            }
        }
    }
}

/// Custom NSTableView subclass to disable default selection/keyboard behavior
/// so the parent SwiftUI view handles Cmd+Up/Down.
private class ChatNSTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        // Don't handle keyboard events — let them propagate to SwiftUI
        nextResponder?.keyDown(with: event)
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - Message Content Analysis (computed once, cached)

/// Number of lines above which a message is auto-collapsed.
private let collapseThreshold = 15
/// Number of preview lines shown when collapsed.
private let collapsedPreviewLines = 5
/// Character count above which we use NSTextView instead of SwiftUI Text.
private let largeTextThreshold = 5_000

/// Pre-analyzed message metadata to avoid recomputing on every render.
private struct MessageAnalysis {
    let isError: Bool
    /// Estimated line count. Exact for short messages, sampled estimate for large ones.
    let lineCount: Int
    let isLong: Bool
    let collapsedPreview: String
    let hasTimestamps: Bool
    /// Display string for line count (e.g., "~1,200" or "42").
    let lineCountDisplay: String

    /// Sample size in bytes for estimating line count in large strings.
    private static let lineCountSampleSize = 4096

    init(content: String) {
        // Only scan the first few characters for error markers
        let prefix100 = content.prefix(100)
        isError = prefix100.contains("⚠") ||
                  prefix100.hasPrefix("Transcription failed") ||
                  prefix100.hasPrefix("Transcription cancelled")

        hasTimestamps = content.utf8.count > 5 && content.contains("[") && content.contains("→")

        // Line counting: exact for small, estimated for large
        let utf8 = content.utf8
        let totalBytes = utf8.count

        if totalBytes <= Self.lineCountSampleSize {
            // Small string: exact count
            var count = 1
            for byte in utf8 {
                if byte == UInt8(ascii: "\n") { count += 1 }
            }
            lineCount = count
            lineCountDisplay = "\(count)"
        } else {
            // Large string: sample first N bytes and extrapolate
            var newlines = 0
            var scanned = 0
            for byte in utf8 {
                if byte == UInt8(ascii: "\n") { newlines += 1 }
                scanned += 1
                if scanned >= Self.lineCountSampleSize { break }
            }
            let estimated = Int(Double(newlines) / Double(scanned) * Double(totalBytes)) + 1
            lineCount = estimated
            lineCountDisplay = "~\(estimated)"
        }
        isLong = lineCount > collapseThreshold

        // Only compute preview if long
        if isLong {
            var lines: [Substring] = []
            var remaining = content[...]
            for _ in 0..<collapsedPreviewLines {
                if let newline = remaining.firstIndex(of: "\n") {
                    lines.append(remaining[..<newline])
                    remaining = remaining[remaining.index(after: newline)...]
                } else {
                    lines.append(remaining)
                    break
                }
            }
            collapsedPreview = lines.joined(separator: "\n") + "\n..."
        } else {
            collapsedPreview = ""
        }
    }
}

// MARK: - Message Bubble

/// A single chat message bubble. Used both for display (in NSTableView cells)
/// and for height measurement (in the coordinator).
///
/// `isExpanded` is managed externally by the table coordinator's `expandedMessages` set
/// so that expansion state survives cell reuse.
private struct MessageBubble: View {
    let message: Message
    var isStreamingThis: Bool = false
    var isExpanded: Bool = false
    let onRetry: () -> Void
    let onCollapseToggle: () -> Void
    @Binding var seekRequest: (storedName: String, time: TimeInterval)?
    @State private var isHovering = false
    @State private var analysis: MessageAnalysis?
    /// Content length at last analysis recomputation — used to throttle during streaming.
    @State private var lastAnalyzedLength: Int = 0

    /// Minimum character delta before recomputing MessageAnalysis during streaming.
    private static let analysisRecomputeThrottle = 500

    private var isUser: Bool { message.role == .user }

    private var currentAnalysis: MessageAnalysis {
        analysis ?? MessageAnalysis(content: message.content)
    }

    var body: some View {
        let info = currentAnalysis

        HStack(alignment: .top, spacing: 4) {
            if isUser {
                Spacer(minLength: 60)
                copyButton
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                ForEach(message.attachments) { attachment in
                    AttachmentView(attachment: attachment, seekRequest: $seekRequest)
                }

                if !message.content.isEmpty {
                    bubbleContent(info: info)
                        .contextMenu { bubbleContextMenu(info: info) }
                } else if isStreamingThis {
                    thinkingBubble
                }

                HStack(spacing: 4) {
                    if info.isError {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }

                    Text(message.timestamp.formatted(.dateTime.hour().minute()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if info.isError {
                        Button("Retry") { onRetry() }
                            .font(.caption2)
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            if !isUser {
                copyButton
                Spacer(minLength: 60)
            }
        }
        .onHover { isHovering = $0 }
        .task(id: message.content.count) {
            // Throttle analysis recomputation during streaming
            let currentLength = message.content.count
            let delta = abs(currentLength - lastAnalyzedLength)
            if analysis == nil || !isStreamingThis || delta >= Self.analysisRecomputeThrottle {
                analysis = MessageAnalysis(content: message.content)
                lastAnalyzedLength = currentLength
            }
        }
    }

    @ViewBuilder
    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.content, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Copy message")
        .padding(.top, 6)
        .opacity(isHovering && !message.content.isEmpty && !isStreamingThis ? 1 : 0)
    }

    @ViewBuilder
    private func bubbleContent(info: MessageAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if info.isLong && !isExpanded && !isStreamingThis {
                Text(info.collapsedPreview)
                    .textSelection(.enabled)
            } else if message.content.count > largeTextThreshold && !isStreamingThis {
                LargeTextView(text: message.content, textColor: isUser ? .white : .labelColor)
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    Text(message.content)
                        .textSelection(.enabled)

                    if isStreamingThis {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(.bottom, 2)
                    }
                }
            }

            // Collapse/expand toggle
            if info.isLong && !isStreamingThis {
                Button(isExpanded ? "Show less" : "Show more (\(info.lineCountDisplay) lines)") {
                    onCollapseToggle()
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(isUser ? .white.opacity(0.8) : Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(bubbleBackground(info: info))
        .foregroundStyle(isUser ? .white : .primary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func bubbleBackground(info: MessageAnalysis) -> some ShapeStyle {
        if info.isError {
            return AnyShapeStyle(Color.red.opacity(0.15))
        }
        if isUser {
            return AnyShapeStyle(Color.accentColor)
        }
        return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var thinkingBubble: some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
            Text("Thinking...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func bubbleContextMenu(info: MessageAnalysis) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.content, forType: .string)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        if info.hasTimestamps {
            Button {
                let plain = message.content
                    .split(separator: "\n")
                    .map { line in
                        let str = String(line)
                        if let bracket = str.range(of: "] ") {
                            return String(str[bracket.upperBound...])
                        }
                        return str
                    }
                    .joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(plain, forType: .string)
            } label: {
                Label("Copy without timestamps", systemImage: "doc.plaintext")
            }
        }

        if info.isError {
            Divider()
            Button { onRetry() } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        }
    }
}

// MARK: - Large Text View (NSTextView for performance with big strings)

/// Uses NSTextView for rendering large text content. Selectable, performant
/// even with hundreds of thousands of characters — unlike SwiftUI Text which freezes.
private struct LargeTextView: NSViewRepresentable {
    let text: String
    let textColor: NSColor

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainerInset = NSSize(width: 0, height: 2)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        let currentLength = textView.string.count
        if currentLength != text.count || textView.string != text {
            textView.string = text
            textView.textColor = textColor
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400

        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let usedRect = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
        let height = usedRect.height + textView.textContainerInset.height * 2

        return CGSize(width: width, height: height)
    }
}

// MARK: - Attachment View

private struct AttachmentView: View {
    let attachment: Attachment
    @Binding var seekRequest: (storedName: String, time: TimeInterval)?

    var body: some View {
        switch attachment.kind {
        case .audio, .video:
            AudioPlayerView(attachment: attachment, seekRequest: $seekRequest)
        case .image:
            ImageAttachmentView(attachment: attachment)
        case .text:
            FileAttachmentBadge(attachment: attachment, iconName: "doc.text")
        }
    }
}

// MARK: - Audio/Video Player with Seek Bar

private struct AudioPlayerView: View {
    let attachment: Attachment
    /// Binding to the ViewModel's seek request — when a transcript timestamp is tapped,
    /// this gets set with (storedName, time) so the matching player can seek.
    @Binding var seekRequest: (storedName: String, time: TimeInterval)?
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isDragging = false
    @State private var timer: Timer?
    @State private var videoThumbnail: NSImage?

    /// Update interval for the seek bar position (seconds).
    private static let progressUpdateInterval: TimeInterval = 0.1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Video thumbnail (if video)
            if attachment.kind == .video, let thumbnail = videoThumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 6) {
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)

                // Seek slider
                Slider(value: Binding(
                    get: { duration > 0 ? currentTime / duration : 0 },
                    set: { newValue in
                        isDragging = true
                        currentTime = newValue * duration
                    }
                ), in: 0...1) { editing in
                    if !editing {
                        // Drag ended — seek to position
                        player?.currentTime = currentTime
                        isDragging = false
                        persistPosition()
                    }
                }
                .controlSize(.small)
                .frame(minWidth: 80)

                // Time display: current / duration
                Text("\(formatTime(currentTime)) / \(formatTime(duration))")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            }

            Text(attachment.originalName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear { loadMetadata() }
        .onDisappear { cleanup() }
        .onChange(of: seekRequest?.time) { _, _ in
            guard let req = seekRequest, req.storedName == attachment.storedName else { return }
            if player == nil { loadMetadata() }
            player?.currentTime = req.time
            currentTime = req.time
            if !isPlaying {
                startPlayback()
            }
            seekRequest = nil
        }
    }

    private func loadMetadata() {
        let url = FileStorage.url(for: attachment.storedName)
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            duration = p.duration
            player = p
            // Restore persisted playback position
            let saved = attachment.playbackPosition
            if saved > 0 && saved < p.duration {
                p.currentTime = saved
                currentTime = saved
            }
        } catch {
            AppLogger.error("Failed to load audio: \(error)", category: "audio")
        }

        // Generate video thumbnail
        if attachment.kind == .video {
            Task.detached(priority: .utility) {
                let thumb = await Self.generateThumbnail(url: url)
                await MainActor.run { videoThumbnail = thumb }
            }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        if player == nil { loadMetadata() }

        // Pause any other playing audio first
        AudioPlaybackManager.shared.didStartPlaying(
            storedName: attachment.storedName,
            onPause: { [self] in pausePlayback() }
        )

        player?.play()
        isPlaying = true
        startTimer()
    }

    private func pausePlayback() {
        player?.pause()
        isPlaying = false
        stopTimer()
        persistPosition()
        AudioPlaybackManager.shared.didStopPlaying(storedName: attachment.storedName)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.progressUpdateInterval, repeats: true) { _ in
            guard let player, !isDragging else { return }
            currentTime = player.currentTime
            if !player.isPlaying {
                isPlaying = false
                persistPosition()
                stopTimer()
                AudioPlaybackManager.shared.didStopPlaying(storedName: attachment.storedName)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func cleanup() {
        persistPosition()
        player?.stop()
        stopTimer()
        AudioPlaybackManager.shared.didStopPlaying(storedName: attachment.storedName)
    }

    /// Saves current playback position to the SwiftData Attachment model.
    private func persistPosition() {
        let pos = player?.currentTime ?? currentTime
        if pos > 0 {
            attachment.playbackPosition = pos
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Generates a thumbnail from the first frame of a video file.
    private static func generateThumbnail(url: URL) async -> NSImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)

        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
    }
}

// MARK: - Image Attachment

private struct ImageAttachmentView: View {
    let attachment: Attachment
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            FileAttachmentBadge(attachment: attachment, iconName: "photo")
        }
        .onAppear {
            let url = FileStorage.url(for: attachment.storedName)
            image = NSImage(contentsOf: url)
        }
    }
}

// MARK: - Generic File Badge

private struct FileAttachmentBadge: View {
    let attachment: Attachment
    let iconName: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
            Text(attachment.originalName)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Title Rename Field (NSViewRepresentable — stable focus)

/// NSTextField for renaming the conversation title in the toolbar.
/// Uses NSViewRepresentable to avoid SwiftUI re-render focus loss.
private struct TitleRenameField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // Only set stringValue on first appear — after that, the coordinator manages it
        if !context.coordinator.didFocus {
            field.stringValue = text
            context.coordinator.didFocus = true
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.selectText(nil)
                context.coordinator.focusEstablished = true
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: TitleRenameField
        var didFocus = false
        var didFinish = false
        var focusEstablished = false

        init(_ parent: TitleRenameField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                parent.text = field.stringValue
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard focusEstablished else { return }
            if !didFinish {
                didFinish = true
                parent.onCancel()
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                didFinish = true
                parent.onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                didFinish = true
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

// MARK: - Input Bar

private let attachableContentTypes: [UTType] = [
    .audio,
    .movie,
    .video,
    .image,
    .plainText,
    .sourceCode,
    .utf8PlainText,
    .text,
]

struct ChatInputBar: View {
    @Bindable var viewModel: ChatViewModel
    let conversation: Conversation
    var isInputFocused: FocusState<Bool>.Binding
    @State private var isShowingFilePicker = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: { isShowingFilePicker = true }) {
                Image(systemName: "paperclip")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isStreaming)
            .help("Attach file (audio, image, or text)")
            .fileImporter(
                isPresented: $isShowingFilePicker,
                allowedContentTypes: attachableContentTypes,
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    for url in urls {
                        let didAccess = url.startAccessingSecurityScopedResource()
                        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                        viewModel.attachFile(from: url, to: conversation)
                    }
                }
            }

            TextEditor(text: $viewModel.messageText)
                .font(.body)
                .frame(minHeight: 20, maxHeight: 90)
                .fixedSize(horizontal: false, vertical: true)
                .scrollContentBackground(.hidden)
                .focused(isInputFocused)
                .disabled(viewModel.isStreaming)
                .overlay(alignment: .topLeading) {
                    if viewModel.messageText.isEmpty {
                        Text("Message...")
                            .font(.body)
                            .foregroundStyle(.placeholder)
                            .allowsHitTesting(false)
                            .padding(.leading, 5)
                            .padding(.top, 0)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    for provider in providers {
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                            let url: URL?
                            if let fileURL = item as? URL {
                                url = fileURL
                            } else if let data = item as? Data {
                                url = URL(dataRepresentation: data, relativeTo: nil)
                            } else {
                                url = nil
                            }
                            guard let url else { return }
                            DispatchQueue.main.async {
                                viewModel.attachFile(from: url, to: conversation)
                            }
                        }
                    }
                    return true
                }
                .onKeyPress(.tab) {
                    // Consume Tab — ContentView's handler switches focus to sidebar
                    return .handled
                }
                .onKeyPress(.return) {
                    if !NSEvent.modifierFlags.contains(.shift) {
                        viewModel.sendMessage()
                        return .handled
                    }
                    return .ignored
                }

            if viewModel.isStreaming {
                Button(action: viewModel.stopStreaming) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                .accessibilityIdentifier("stopStreamingButton")
                .buttonStyle(.borderless)
                .help("Stop generation")
            } else {
                Button(action: viewModel.sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .accessibilityIdentifier("sendMessageButton")
                .buttonStyle(.borderless)
                .disabled(viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(12)
    }
}
