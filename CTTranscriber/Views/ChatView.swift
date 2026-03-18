import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import AVKit

struct ChatView: View {
    let conversation: Conversation
    @Bindable var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool
    @State private var isRenamingTitle = false
    @State private var renameTitleText = ""
    @Environment(\.fontScale) private var fontScale
    var body: some View {
        VStack(spacing: 0) {
            ChatTableView(messages: viewModel.sortedMessages(for: conversation),
                          isStreaming: viewModel.isStreamingCurrentConversation,
                          onRetry: { message in viewModel.retryMessage(message, in: conversation) },
                          onDropFiles: { urls in
                              for url in urls {
                                  viewModel.attachFile(from: url, to: conversation)
                              }
                          },
                          onClickBackground: { viewModel.requestInputFocus() },
                          seekRequest: $viewModel.seekRequest,
                          fontScale: fontScale,
                          conversationID: conversation.id,
                          scrollToTopTrigger: viewModel.scrollToTopTrigger,
                          scrollToBottomTrigger: viewModel.scrollToBottomTrigger)

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

            // Floating mini-player — shown when media is playing in this conversation
            if AudioPlaybackManager.shared.currentlyPlayingID != nil,
               AudioPlaybackManager.shared.conversationID == conversation.id {
                MiniPlayerBar()
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
                        fontSize: CGFloat(NSFont.systemFontSize) * CGFloat(fontScale),
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
                    HStack(spacing: 4) {
                        Text(conversation.title)
                            .font(ScaledFont(scale: fontScale).headline)
                            .lineLimit(1)
                            .onTapGesture(count: 2) {
                                renameTitleText = conversation.title
                                isRenamingTitle = true
                            }
                        AutoTitleButton(
                            fontScale: fontScale,
                            isGenerating: viewModel.isGeneratingTitle,
                            disabled: viewModel.isStreamingCurrentConversation || viewModel.isGeneratingTitle
                        ) {
                            viewModel.autoNameConversation(conversation)
                        }
                    }
                }
            }
        }
        .onChange(of: viewModel.focusCounter) { _, _ in
            isInputFocused = true
        }
    }

}

// MARK: - Transcription Progress

private struct TranscriptionProgressBar: View {
    let progress: Double
    let onStop: () -> Void
    @Environment(\.fontScale) private var fontScale

    var body: some View {
        let sf = ScaledFont(scale: fontScale)
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(Color.accentColor)
            Text("Transcribing...")
                .font(sf.caption)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
            Text("\(Int(progress * 100))%")
                .font(sf.caption)
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
    @Environment(\.fontScale) private var fontScale

    var body: some View {
        let sf = ScaledFont(scale: fontScale)
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(sf.caption)
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
    /// Hash of message state for change detection. Includes content length + attachment state.
    static func messageHash(_ msg: Message) -> Int {
        var h = msg.content.count
        for att in msg.attachments {
            h = h &* 31 &+ (att.convertedName?.count ?? 0)
        }
        return h
    }

    let messages: [Message]
    let isStreaming: Bool
    let onRetry: (Message) -> Void
    let onDropFiles: ([URL]) -> Void
    let onClickBackground: () -> Void
    @Binding var seekRequest: (storedName: String, time: TimeInterval)?
    let fontScale: Double
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
        context.coordinator.fontScale = fontScale
        tableView.onClickBackground = onClickBackground

        // Set initial data so the table isn't empty on first render
        context.coordinator.messages = messages
        context.coordinator.conversationID = conversationID
        context.coordinator.isStreaming = isStreaming
        context.coordinator.contentLengthSnapshot = Dictionary(
            uniqueKeysWithValues: messages.map { ($0.id, Self.messageHash($0)) }
        )

        // Reload after setting data — the table already queried numberOfRows
        // during setup (returning 0), so it needs an explicit reload.
        DispatchQueue.main.async {
            tableView.reloadData()
            if !messages.isEmpty {
                context.coordinator.scrollToBottom(animated: false)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let oldMessages = coordinator.messages
        let oldStreaming = coordinator.isStreaming
        let oldConversationID = coordinator.conversationID

        AppLogger.debug("updateNSView: msgs=\(messages.count) oldMsgs=\(oldMessages.count) convoID=\(conversationID?.uuidString.prefix(8) ?? "nil") oldConvoID=\(oldConversationID?.uuidString.prefix(8) ?? "nil")", category: "table")

        coordinator.onRetry = onRetry
        coordinator.onDropFiles = onDropFiles
        coordinator.seekRequest = $seekRequest

        let oldFontScale = coordinator.fontScale
        coordinator.fontScale = fontScale
        coordinator.isStreaming = isStreaming

        // Skip all row updates during live resize — heights recalculated in viewDidEndLiveResize
        if let chatTable = coordinator.tableView as? ChatNSTableView, chatTable.isLiveResizing {
            coordinator.messages = messages
            return
        }

        // Font scale changed — invalidate all heights and reload twice.
        // First reload creates cells with new font; second pass remeasures heights
        // correctly (sizeThatFits needs the environment to propagate first).
        if abs(fontScale - oldFontScale) > 0.01, let tableView = coordinator.tableView {
            coordinator.heightCache.removeAll()
            tableView.intercellSpacing = NSSize(width: 0, height: 12 * fontScale)
            tableView.reloadData()
            // Second pass — clear cache again, remeasure, and reload.
            // The first pass cached heights before the environment fully propagated;
            // the second pass gets correct measurements.
            DispatchQueue.main.async {
                coordinator.heightCache.removeAll()
                let allRows = IndexSet(integersIn: 0..<coordinator.messages.count)
                tableView.noteHeightOfRows(withIndexesChanged: allRows)
                tableView.reloadData()
            }
            return
        }

        guard let tableView = coordinator.tableView else { return }

        // Conversation switch — full reload + scroll to bottom
        if conversationID != oldConversationID {
            coordinator.conversationID = conversationID
            coordinator.messages = messages
            coordinator.heightCache.removeAll()

            coordinator.expandedMessages.removeAll()
            coordinator.contentLengthSnapshot = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, Self.messageHash($0)) })
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

            // Detect content changes using a snapshot.
            // SwiftData models are reference types — oldMessages and messages
            // share the same objects, so we can't compare them directly.
            // Also track attachment state (convertedName) for video conversion completion.
            var changedRows = IndexSet()
            for i in messages.indices {
                let msg = messages[i]
                let currentHash = Self.messageHash(msg)
                let snapshotHash = coordinator.contentLengthSnapshot[msg.id]
                if snapshotHash == nil || snapshotHash != currentHash {
                    changedRows.insert(i)
                }
            }

            if isStreaming, let lastRow = messages.indices.last {
                changedRows.insert(lastRow)
            }

            // Update snapshot
            for msg in messages {
                coordinator.contentLengthSnapshot[msg.id] = Self.messageHash(msg)
            }

            if !changedRows.isEmpty {
                // Invalidate height cache for changed rows
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
        var fontScale: Double = 1.0
        var conversationID: UUID?

        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?

        /// Snapshot of content lengths per message ID — used to detect in-place content changes.
        /// Needed because SwiftData Message objects are reference types: comparing old vs new
        /// messages gives the same object, so content appears unchanged.
        var contentLengthSnapshot: [UUID: Int] = [:]
        /// Cached row heights keyed by message ID. Invalidated on content change, expand/collapse, resize.
        var heightCache: [UUID: CGFloat] = [:]
        /// Messages the user has expanded (for long/collapsible messages).
        var expandedMessages: Set<UUID> = []

        var lastTopTrigger: Int = 0
        var lastBottomTrigger: Int = 0

        /// Throttle for scroll-during-streaming
        private var lastStreamingScrollTime: Date = .distantPast
        private static let streamingScrollInterval: TimeInterval = 0.2


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
            .environment(\.fontScale, fontScale)
            .font(.system(size: CGFloat(NSFont.systemFontSize) * CGFloat(fontScale)))

            let cell = NSHostingView(rootView: bubble)
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
            let isStreamingThis = isStreaming && row == messages.count - 1 && message.role == .assistant

            // Don't cache streaming row — it changes every token
            if !isStreamingThis, let cached = heightCache[message.id] {
                return cached
            }

            let height = measureRowHeight(message: message, row: row, tableView: tableView)

            if !isStreamingThis {
                heightCache[message.id] = height
            }
            return height
        }

        /// Expensive height calculation — only called on cache miss.
        private func measureRowHeight(message: Message, row: Int, tableView: NSTableView) -> CGFloat {
            let isExpanded = expandedMessages.contains(message.id)
            let isStreamingThis = isStreaming && row == messages.count - 1 && message.role == .assistant
            let columnWidth = tableView.tableColumns.first?.width ?? tableView.bounds.width
            let targetWidth = max(columnWidth, 200)

            let seekBinding = seekRequest ?? .constant(nil)
            let bubble = MessageBubble(
                message: message,
                isStreamingThis: isStreamingThis,
                isExpanded: isExpanded,
                onRetry: {},
                onCollapseToggle: {},
                seekRequest: seekBinding
            )
            .padding(.horizontal, 16)
            .environment(\.fontScale, fontScale)
            .font(.system(size: CGFloat(NSFont.systemFontSize) * CGFloat(fontScale)))
            .frame(width: targetWidth)

            let controller = NSHostingController(rootView: bubble)
            let size = controller.sizeThatFits(in: NSSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude))
            return max(size.height, 30)
        }

        // MARK: - Video Aspect Ratio (synchronous)

        /// Cache of video aspect ratios keyed by storedName.
        private static var videoAspectRatioCache: [String: CGFloat] = [:]

        /// Returns the cached aspect ratio. Returns 16:9 fallback if not yet computed.
        /// Call `precomputeVideoAspectRatio` on a background thread to populate the cache.
        static func videoAspectRatio(url: URL) -> CGFloat {
            let key = url.lastPathComponent
            return videoAspectRatioCache[key] ?? (16.0 / 9.0)
        }

        /// Pre-computes and caches the aspect ratio. Safe to call from any thread.
        /// Call this from a background Task when a video attachment is added.
        static func precomputeVideoAspectRatio(url: URL) {
            let key = url.lastPathComponent
            guard videoAspectRatioCache[key] == nil else { return }
            let asset = AVAsset(url: url)
            if let track = asset.tracks(withMediaType: .video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                let w = abs(size.width)
                let h = abs(size.height)
                if w > 0 && h > 0 {
                    videoAspectRatioCache[key] = w / h
                }
            }
        }

        // MARK: - Text Height Measurement

        /// Measures the rendered height of a text string at a given width using NSTextStorage.
        /// More reliable than NSHostingView measurement for large text blocks.
        static func measureTextHeight(_ text: String, width: CGFloat, fontSize: CGFloat = NSFont.systemFontSize) -> CGFloat {
            let textStorage = NSTextStorage(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize)
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

            guard let tableView else { return }

            // Invalidate cached height for this message
            heightCache.removeValue(forKey: messageID)

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
                .environment(\.fontScale, fontScale)
                .font(.system(size: CGFloat(NSFont.systemFontSize) * CGFloat(fontScale)))

            }

            let savedOrigin = scrollView?.contentView.bounds.origin ?? .zero

            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                                 columnIndexes: IndexSet(integer: 0))

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
    var onClickBackground: (() -> Void)?
    private var liveResizeStartWidth: CGFloat = 0
    var isLiveResizing = false

    override func keyDown(with event: NSEvent) {
        nextResponder?.keyDown(with: event)
    }

    override var acceptsFirstResponder: Bool { false }

    // Telegram pattern: recalculate all heights after resize finishes, not during
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        liveResizeStartWidth = frame.width
        isLiveResizing = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        isLiveResizing = false
        if abs(frame.width - liveResizeStartWidth) > 1 {
            // Invalidate all heights — width changed, text wrapping different
            if let coordinator = delegate as? ChatTableView.Coordinator {
                coordinator.heightCache.removeAll()
            }
            let allRows = IndexSet(integersIn: 0..<numberOfRows)
            noteHeightOfRows(withIndexesChanged: allRows)
            reloadData()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow == -1 {
            // Clicked on empty area (not on a row) — focus the input
            onClickBackground?()
        }
        super.mouseDown(with: event)
    }
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
        // Error markers: ⚠ [LLM] or ⚠ [Transcription] prefixes, or legacy cancelled message
        let prefix100 = content.prefix(100)
        isError = prefix100.contains("⚠") ||
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
    @Environment(\.fontScale) private var fontScale
    private var sf: ScaledFont { ScaledFont(scale: fontScale) }
    /// Scale a base padding/spacing value by fontScale.
    private func sp(_ base: CGFloat) -> CGFloat { base * CGFloat(fontScale) }

    /// Minimum character delta before recomputing MessageAnalysis during streaming.
    private static let analysisRecomputeThrottle = 500

    private var isUser: Bool { message.role == .user }

    private var currentAnalysis: MessageAnalysis {
        analysis ?? MessageAnalysis(content: message.content)
    }

    var body: some View {
        let info = currentAnalysis

        HStack(alignment: .top, spacing: sp(4)) {
            if isUser {
                Spacer(minLength: sp(60))
                copyButton
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: sp(4)) {
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
                            .font(sf.caption2)
                            .foregroundStyle(.red)
                    }

                    Text(message.timestamp.formatted(.dateTime.hour().minute()))
                        .font(sf.caption2)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))

                    if info.isError {
                        Button("Retry") { onRetry() }
                            .font(sf.caption2)
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            if !isUser {
                copyButton
                Spacer(minLength: sp(60))
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
                .font(sf.caption)
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
                LargeTextView(text: message.content, textColor: isUser ? .white : .labelColor,
                              fontSize: CGFloat(NSFont.systemFontSize) * CGFloat(fontScale))
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
                .font(sf.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(isUser ? .white.opacity(0.8) : Color.accentColor)
            }
        }
        .padding(.horizontal, sp(12))
        .padding(.vertical, sp(8))
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
        // Light gray bubble that's clearly visible against the window background.
        // In light mode: ~#E8E8EA; in dark mode: ~#3A3A3C (adapts automatically).
        return AnyShapeStyle(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
    }

    @ViewBuilder
    private var thinkingBubble: some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
            Text("Thinking...")
                .font(sf.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, sp(12))
        .padding(.vertical, sp(8))
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: sp(12)))
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

        if info.hasTimestamps {
            Divider()
            // Parse the first timestamp from the content and offer "Play from start"
            if let firstTimestamp = parseFirstTimestamp(from: message.content) {
                Button {
                    // Find the audio storedName from the previous message's attachment
                    if let audioName = findAudioAttachment() {
                        seekRequest = (storedName: audioName, time: firstTimestamp)
                    }
                } label: {
                    Label("Play from \(formatSeekTime(firstTimestamp))", systemImage: "play.fill")
                }
            }
        }

        if info.isError {
            Divider()
            Button { onRetry() } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        }
    }

    /// Parses the first `[MM:SS` or `[SS.SS` timestamp from transcript text.
    private func parseFirstTimestamp(from text: String) -> TimeInterval? {
        // Match [0.00 → or [1:23.45 →
        guard let bracketRange = text.range(of: "[") else { return nil }
        let afterBracket = text[bracketRange.upperBound...]
        guard let arrowRange = afterBracket.range(of: " →") ?? afterBracket.range(of: "→") else { return nil }
        let timeStr = String(afterBracket[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        return parseTimestamp(timeStr)
    }

    /// Parses a timestamp string like "0.00", "1:23", "1:23.45" into seconds.
    private func parseTimestamp(_ str: String) -> TimeInterval? {
        let parts = str.split(separator: ":")
        if parts.count == 2 {
            // MM:SS or MM:SS.ss
            guard let min = Double(parts[0]), let sec = Double(parts[1]) else { return nil }
            return min * 60 + sec
        } else if parts.count == 1 {
            // SS.ss
            return Double(parts[0])
        }
        return nil
    }

    /// Finds the storedName of an audio/video attachment from the message before this one.
    private func findAudioAttachment() -> String? {
        guard let conversation = message.conversation else { return nil }
        let sorted = conversation.messages.sorted { $0.timestamp < $1.timestamp }
        guard let myIndex = sorted.firstIndex(where: { $0.id == message.id }), myIndex > 0 else { return nil }
        // Look at the message before this one for an audio/video attachment
        let prev = sorted[myIndex - 1]
        return prev.attachments.first(where: { $0.kind == .audio || $0.kind == .video })?.storedName
    }

    private func formatSeekTime(_ time: TimeInterval) -> String {
        let min = Int(time) / 60
        let sec = Int(time) % 60
        return String(format: "%d:%02d", min, sec)
    }
}

// MARK: - Large Text View (NSTextView for performance with big strings)

/// Uses NSTextView for rendering large text content. Selectable, performant
/// even with hundreds of thousands of characters — unlike SwiftUI Text which freezes.
private struct LargeTextView: NSViewRepresentable {
    let text: String
    let textColor: NSColor
    var fontSize: CGFloat = NSFont.systemFontSize

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: fontSize)
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
        textView.font = .systemFont(ofSize: fontSize)
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

    /// File extensions that AVPlayer cannot play natively on macOS.
    private static let unsupportedVideoExtensions: Set<String> = ["webm", "mkv", "flv", "wmv"]

    private var isUnsupportedVideo: Bool {
        let ext = attachment.storedName.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        // Also check original name
        let origExt = attachment.originalName.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        return Self.unsupportedVideoExtensions.contains(ext) || Self.unsupportedVideoExtensions.contains(origExt)
    }

    var body: some View {
        switch attachment.kind {
        case .audio:
            AudioPlayerView(attachment: attachment, seekRequest: $seekRequest)
        case .video:
            if isUnsupportedVideo && attachment.convertedName == nil {
                UnsupportedVideoView(attachment: attachment, isConverting: true)
            } else {
                let playName = attachment.convertedName ?? attachment.storedName
                let url = FileStorage.url(for: playName)
                let ratio = ChatTableView.Coordinator.videoAspectRatio(url: url)
                VideoPlayerView(attachment: attachment,
                                playbackStoredName: attachment.convertedName,
                                initialAspectRatio: ratio,
                                seekRequest: $seekRequest
                )
            }
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
    @Environment(\.fontScale) private var fontScale

    /// Update interval for the seek bar position (seconds).
    private static let progressUpdateInterval: TimeInterval = 0.1

    private func sp(_ base: CGFloat) -> CGFloat { base * CGFloat(fontScale) }

    var body: some View {
        let sf = ScaledFont(scale: fontScale)
        VStack(alignment: .leading, spacing: sp(4)) {
            // Video thumbnail (if video)
            if attachment.kind == .video, let thumbnail = videoThumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: sp(160))
                    .clipShape(RoundedRectangle(cornerRadius: sp(6)))
            }

            HStack(spacing: sp(6)) {
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(sf.title2)
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
                .frame(minWidth: sp(80))

                // Time display: current / duration
                Text("\(formatTime(currentTime)) / \(formatTime(duration))")
                    .font(sf.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .frame(minWidth: sp(80), alignment: .trailing)
            }

            Text(attachment.originalName)
                .font(sf.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, sp(8))
        .padding(.vertical, sp(6))
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: sp(6)))
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

        AudioPlaybackManager.shared.didStartPlaying(
            storedName: attachment.storedName,
            displayName: attachment.originalName,
            conversationID: attachment.message?.conversation?.id,
            duration: duration,
            player: player,
            onPause: { [self] in pausePlayback() },
            onSeek: { [self] time in
                player?.currentTime = time
                currentTime = time
                if !isPlaying {
                    player?.play()
                    isPlaying = true
                    startTimer()
                }
            },
            onGetCurrentTime: {
                (AudioPlaybackManager.shared.activePlayer as? AVAudioPlayer)?.currentTime ?? 0
            }
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
            AudioPlaybackManager.shared.currentTime = currentTime
            if !player.isPlaying {
                isPlaying = false
                persistPosition()
                stopTimer()
                AudioPlaybackManager.shared.didFinishPlaying(storedName: attachment.storedName)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func cleanup() {
        persistPosition()
        // Don't stop playback when scrolling out — the mini-player takes over.
        // Only stop the UI timer; the AVAudioPlayer continues in the background.
        // The AudioPlaybackManager keeps tracking the state.
        if !isPlaying {
            player?.stop()
            AudioPlaybackManager.shared.didStopPlaying(storedName: attachment.storedName)
        }
        stopTimer()
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

// MARK: - Video Player

private struct VideoPlayerView: View {
    let attachment: Attachment
    var playbackStoredName: String?
    var initialAspectRatio: CGFloat = 16.0 / 9.0
    @Binding var seekRequest: (storedName: String, time: TimeInterval)?
    @State private var avPlayer: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isDragging = false
    @State private var timeObserver: Any?
    @State private var videoAspectRatio: CGFloat?
    @Environment(\.fontScale) private var fontScale

    private func sp(_ base: CGFloat) -> CGFloat { base * CGFloat(fontScale) }

    private var effectiveAspectRatio: CGFloat {
        videoAspectRatio ?? initialAspectRatio
    }

    /// Compute video display dimensions from aspect ratio.
    private var videoSize: (width: CGFloat, height: CGFloat) {
        let maxW = sp(350)
        let maxH = sp(300)
        let ratio = effectiveAspectRatio
        let h = min(maxH, maxW / ratio)
        let w = h * ratio
        return (w, h)
    }

    var body: some View {
        let sf = ScaledFont(scale: fontScale)
        let vs = videoSize
        VStack(alignment: .leading, spacing: sp(4)) {
            // Video player — always reserve the frame for correct height measurement
            if let avPlayer {
                VideoPlayerNSView(player: avPlayer)
                    .frame(width: vs.width, height: vs.height)
                    .clipShape(RoundedRectangle(cornerRadius: sp(6)))
            } else {
                // Placeholder with same dimensions — ensures correct row height before player loads
                RoundedRectangle(cornerRadius: sp(6))
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                    .frame(width: vs.width, height: vs.height)
            }

            Text(attachment.originalName)
                .font(sf.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: vs.width, alignment: .leading)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(sp(4))
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: sp(6)))
        .onAppear { loadVideo() }
        .onDisappear { cleanup() }
        .onChange(of: seekRequest?.time) { _, _ in
            guard let req = seekRequest, req.storedName == attachment.storedName else { return }
            avPlayer?.seek(to: CMTime(seconds: req.time, preferredTimescale: 600))
            currentTime = req.time
            if !isPlaying { startPlayback() }
            seekRequest = nil
        }
    }

    private func loadVideo() {
        let url = FileStorage.url(for: playbackStoredName ?? attachment.storedName)

        // Use pre-computed aspect ratio from cache (populated on attach, non-blocking)
        let cachedRatio = ChatTableView.Coordinator.videoAspectRatio(url: url)
        if cachedRatio != 16.0 / 9.0 {
            videoAspectRatio = cachedRatio
        }

        let player = AVPlayer(url: url)
        self.avPlayer = player

        // Get duration and aspect ratio async (non-blocking)
        Task {
            // Compute aspect ratio on background if not cached
            if videoAspectRatio == nil {
                if let tracks = try? await player.currentItem?.asset.loadTracks(withMediaType: .video),
                   let track = tracks.first,
                   let size = try? await track.load(.naturalSize),
                   let transform = try? await track.load(.preferredTransform) {
                    let transformed = size.applying(transform)
                    let w = abs(transformed.width)
                    let h = abs(transformed.height)
                    if w > 0 && h > 0 {
                        await MainActor.run { videoAspectRatio = w / h }
                    }
                }
            }

            if let d = try? await player.currentItem?.asset.load(.duration) {
                let seconds = CMTimeGetSeconds(d)
                if seconds.isFinite {
                    await MainActor.run { duration = seconds }
                }
            }
        }

        // Restore saved position
        let saved = attachment.playbackPosition
        if saved > 0 {
            player.seek(to: CMTime(seconds: saved, preferredTimescale: 600))
            currentTime = saved
        }

        // Periodic time observer
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard !isDragging else { return }
            let seconds = CMTimeGetSeconds(time)
            if seconds.isFinite {
                currentTime = seconds
                AudioPlaybackManager.shared.currentTime = seconds
            }
            // Detect end of playback
            if let item = player.currentItem,
               CMTimeGetSeconds(item.duration).isFinite,
               seconds >= CMTimeGetSeconds(item.duration) - 0.1 {
                isPlaying = false
                AudioPlaybackManager.shared.didFinishPlaying(storedName: attachment.storedName)
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
        AudioPlaybackManager.shared.didStartPlaying(
            storedName: attachment.storedName,
            displayName: attachment.originalName,
            conversationID: attachment.message?.conversation?.id,
            duration: duration,
            player: avPlayer,
            onPause: {
                // Use manager's retained player — survives cell destruction
                let mgr = AudioPlaybackManager.shared
                (mgr.activePlayer as? AVPlayer)?.pause()
                if let id = mgr.currentlyPlayingID { mgr.didStopPlaying(storedName: id) }
            },
            onSeek: { time in
                guard let p = AudioPlaybackManager.shared.activePlayer as? AVPlayer else { return }
                p.seek(to: CMTime(seconds: time, preferredTimescale: 600))
                p.play()
            },
            onGetCurrentTime: {
                guard let p = AudioPlaybackManager.shared.activePlayer as? AVPlayer else { return 0 }
                let t = CMTimeGetSeconds(p.currentTime())
                return t.isFinite ? t : 0
            }
        )
        avPlayer?.play()
        isPlaying = true
    }

    private func pausePlayback() {
        avPlayer?.pause()
        isPlaying = false
        persistPosition()
        AudioPlaybackManager.shared.didStopPlaying(storedName: attachment.storedName)
    }

    private func cleanup() {
        persistPosition()
        // Don't stop playback when scrolling out — the mini-player takes over.
        if !isPlaying {
            avPlayer?.pause()
            AudioPlaybackManager.shared.didStopPlaying(storedName: attachment.storedName)
        }
        if let observer = timeObserver {
            avPlayer?.removeTimeObserver(observer)
        }
        timeObserver = nil
    }

    private func persistPosition() {
        attachment.playbackPosition = currentTime
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// NSViewRepresentable wrapping AVPlayerView for native macOS video rendering.
private struct VideoPlayerNSView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

// MARK: - Unsupported Video (WebM, MKV, etc.)

private struct UnsupportedVideoView: View {
    let attachment: Attachment
    var isConverting: Bool = false
    @Environment(\.fontScale) private var fontScale

    private func sp(_ base: CGFloat) -> CGFloat { base * CGFloat(fontScale) }

    var body: some View {
        let sf = ScaledFont(scale: fontScale)
        VStack(spacing: sp(6)) {
            Image(systemName: "film")
                .font(.system(size: 28 * CGFloat(fontScale)))
                .foregroundStyle(.secondary)
            Text(attachment.originalName)
                .font(sf.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if isConverting {
                HStack(spacing: sp(4)) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Converting to MP4 for playback...")
                        .font(sf.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Playback not supported for this format.")
                    .font(sf.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(sp(12))
        .frame(maxWidth: sp(300))
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: sp(6)))
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
        .task {
            // Load image on background thread to avoid blocking scroll
            let url = FileStorage.url(for: attachment.storedName)
            let loaded = await Task.detached(priority: .utility) {
                NSImage(contentsOf: url)
            }.value
            image = loaded
        }
    }
}

// MARK: - Generic File Badge

private struct FileAttachmentBadge: View {
    let attachment: Attachment
    let iconName: String
    @Environment(\.fontScale) private var fontScale

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
            Text(attachment.originalName)
                .lineLimit(1)
        }
        .font(ScaledFont(scale: fontScale).caption)
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Auto Title Button

private struct AutoTitleButton: View {
    let fontScale: Double
    let isGenerating: Bool
    let disabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        if isGenerating {
            ProgressView()
                .controlSize(.small)
                .help("Generating title...")
        } else {
            Button(action: action) {
                Image(systemName: "sparkles")
                    .font(ScaledFont(scale: fontScale).caption)
                    .foregroundStyle(isHovering ? Color.accentColor : .secondary)
                    .scaleEffect(isHovering ? 1.15 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isHovering)
            }
            .buttonStyle(.borderless)
            .onHover { isHovering = $0 }
            .help("Generate title from conversation content using LLM")
            .disabled(disabled)
        }
    }
}

// MARK: - Mini Player Bar

/// Compact player bar shown when the playing audio/video is scrolled out of view.
private struct MiniPlayerBar: View {
    @Environment(\.fontScale) private var fontScale
    private var manager: AudioPlaybackManager { .shared }

    private func sp(_ base: CGFloat) -> CGFloat { base * CGFloat(fontScale) }

    var body: some View {
        let sf = ScaledFont(scale: fontScale)
        HStack(spacing: sp(8)) {
            Button(action: { manager.togglePlayPause() }) {
                Image(systemName: manager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(sf.title3)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)

            if let name = manager.currentlyPlayingName {
                Text(name)
                    .font(sf.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }

            Slider(value: Binding(
                get: { manager.duration > 0 ? manager.currentTime / manager.duration : 0 },
                set: { manager.seek(to: $0 * manager.duration) }
            ), in: 0...1)
            .controlSize(.small)

            Text(formatTime(manager.currentTime))
                .font(sf.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: sp(40), alignment: .trailing)
        }
        .padding(.horizontal, sp(12))
        .padding(.vertical, sp(4))
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Title Rename Field (NSViewRepresentable — stable focus)

/// NSTextField for renaming the conversation title in the toolbar.
/// Uses NSViewRepresentable to avoid SwiftUI re-render focus loss.
private struct TitleRenameField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = NSFont.systemFontSize
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
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
    @Environment(\.fontScale) private var fontScale

    var body: some View {
        let sf = ScaledFont(scale: fontScale)
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: { isShowingFilePicker = true }) {
                Image(systemName: "paperclip")
                    .font(sf.title3)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isStreamingCurrentConversation)
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
                .font(sf.body)
                .frame(minHeight: 20, maxHeight: 90)
                .fixedSize(horizontal: false, vertical: true)
                .scrollContentBackground(.hidden)
                .focused(isInputFocused)
                .disabled(viewModel.isStreamingCurrentConversation)
                .overlay(alignment: .topLeading) {
                    if viewModel.messageText.isEmpty {
                        Text("Message...")
                            .font(sf.body)
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
                    return .handled
                }
                .onKeyPress(keys: [.upArrow], phases: .down) { keyPress in
                    if keyPress.modifiers.contains(.command) {
                        viewModel.scrollToTop()
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(keys: [.downArrow], phases: .down) { keyPress in
                    if keyPress.modifiers.contains(.command) {
                        viewModel.scrollToBottom()
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.return) {
                    if !NSEvent.modifierFlags.contains(.shift) {
                        viewModel.sendMessage()
                        return .handled
                    }
                    return .ignored
                }

            if viewModel.isStreamingCurrentConversation {
                Button(action: viewModel.stopStreaming) {
                    Image(systemName: "stop.circle.fill")
                        .font(sf.title2)
                        .foregroundStyle(.red)
                }
                .accessibilityIdentifier("stopStreamingButton")
                .buttonStyle(.borderless)
                .help("Stop generation")
            } else {
                Button(action: viewModel.sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(sf.title2)
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
