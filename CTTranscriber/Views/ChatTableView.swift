import SwiftUI
import AVFoundation

/// Number of lines above which a message is auto-collapsed.
let collapseThreshold = 15
/// Number of preview lines shown when collapsed.
let collapsedPreviewLines = 5
/// Character count above which we use NSTextView instead of SwiftUI Text.
let largeTextThreshold = 5_000

// MARK: - Chat Table View (NSTableView-backed message list)

/// Replaces the SwiftUI ScrollView+LazyVStack with NSTableView for:
/// - Reliable scroll-to-bottom (no LazyVStack height estimation issues)
/// - ID-based scroll preservation on expand/collapse
/// - Targeted row updates during streaming (no full list refresh)
/// - Cell reuse for memory efficiency
struct ChatTableView: NSViewRepresentable {
    /// Hash of message state for change detection. Includes content length + attachment state.
    /// Guards against accessing properties on deleted SwiftData objects — during view updates,
    /// model objects may have been deleted from the context between body evaluation and updateNSView.
    static func messageHash(_ msg: Message) -> Int {
        guard !msg.isDeleted, msg.modelContext != nil else { return 0 }
        return msg.content.count
    }

    /// Returns a string encoding the video layout state for a message's attachments.
    /// Empty string if no video attachments. Changes when aspect ratio loads or conversion completes.
    static func videoLayoutKey(for msg: Message) -> String {
        guard !msg.isDeleted, msg.modelContext != nil else { return "" }
        var parts: [String] = []
        for att in msg.attachments where att.kind == .video {
            guard !att.isDeleted, att.modelContext != nil else { continue }
            let playName = att.convertedName ?? att.storedName
            let url = FileStorage.url(for: playName)
            let ratio = Coordinator.videoAspectRatio(url: url)
            parts.append("\(playName):\(ratio)")
        }
        return parts.joined(separator: "|")
    }

    let messages: [Message]
    let isStreaming: Bool
    let onRetry: (Message) -> Void
    let onDropFiles: ([URL]) -> Void
    let onClickBackground: () -> Void
    @Binding var seekRequest: (id: UUID, storedName: String, time: TimeInterval)?
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
        // Filter out deleted model objects — SwiftUI may call updateNSView with stale
        // references after modelContext.delete() + save() runs between body and here.
        let liveMessages = messages.filter { !$0.isDeleted && $0.modelContext != nil }
        let oldMessages = coordinator.messages
        let oldStreaming = coordinator.isStreaming
        let oldConversationID = coordinator.conversationID

        AppLogger.debug("updateNSView: msgs=\(liveMessages.count) oldMsgs=\(oldMessages.count) convoID=\(conversationID?.uuidString.prefix(8) ?? "nil") oldConvoID=\(oldConversationID?.uuidString.prefix(8) ?? "nil")", category: "table")

        coordinator.onRetry = onRetry
        coordinator.onDropFiles = onDropFiles
        coordinator.seekRequest = $seekRequest

        let oldFontScale = coordinator.fontScale
        coordinator.fontScale = fontScale
        coordinator.isStreaming = isStreaming

        // Skip all row updates during live resize — heights recalculated in viewDidEndLiveResize
        if let chatTable = coordinator.tableView as? ChatNSTableView, chatTable.isLiveResizing {
            coordinator.messages = liveMessages
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
            coordinator.messages = liveMessages
            coordinator.heightCache.removeAll()

            coordinator.expandedMessages.removeAll()
            coordinator.contentLengthSnapshot = Dictionary(uniqueKeysWithValues: liveMessages.map { ($0.id, Self.messageHash($0)) })
            coordinator.videoLayoutSnapshot.removeAll()
            for msg in liveMessages {
                let key = Self.videoLayoutKey(for: msg)
                if !key.isEmpty { coordinator.videoLayoutSnapshot[msg.id] = key }
            }
            tableView.reloadData()
            DispatchQueue.main.async {
                coordinator.scrollToBottom(animated: false)
            }
            return
        }

        let oldIDs = oldMessages.map(\.id)
        let newIDs = liveMessages.map(\.id)

        if oldIDs == newIDs {
            // Same messages — find which rows have content changes
            coordinator.messages = liveMessages

            // Detect content changes using a snapshot.
            // SwiftData models are reference types — oldMessages and liveMessages
            // share the same objects, so we can't compare them directly.
            // Also track attachment state (convertedName) for video conversion completion.
            var changedRows = IndexSet()
            for i in liveMessages.indices {
                let msg = liveMessages[i]
                let currentHash = Self.messageHash(msg)
                let snapshotHash = coordinator.contentLengthSnapshot[msg.id]
                if snapshotHash == nil || snapshotHash != currentHash {
                    changedRows.insert(i)
                }
            }

            if isStreaming, let lastRow = liveMessages.indices.last {
                changedRows.insert(lastRow)
            }

            // Detect video layout changes (aspect ratio loaded, conversion completed)
            for i in liveMessages.indices {
                let msg = liveMessages[i]
                let videoKey = Self.videoLayoutKey(for: msg)
                if let prev = coordinator.videoLayoutSnapshot[msg.id], prev != videoKey {
                    changedRows.insert(i)
                }
                if videoKey != "" {
                    coordinator.videoLayoutSnapshot[msg.id] = videoKey
                }
            }

            // Update snapshot
            for msg in liveMessages {
                coordinator.contentLengthSnapshot[msg.id] = Self.messageHash(msg)
            }

            if !changedRows.isEmpty {
                // Invalidate height cache for changed rows
                for row in changedRows {
                    coordinator.heightCache.removeValue(forKey: liveMessages[row].id)
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
            coordinator.messages = liveMessages

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
        var seekRequest: Binding<(id: UUID, storedName: String, time: TimeInterval)?>?
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

        /// Tracks video layout state per message: aspect ratio + conversion status.
        /// When this changes for a message, its row height must be invalidated.
        var videoLayoutSnapshot: [UUID: String] = [:]

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
            guard row < messages.count, !messages[row].isDeleted, messages[row].modelContext != nil else { return nil }
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
            guard row < messages.count, !messages[row].isDeleted, messages[row].modelContext != nil else { return 44 }
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

            // Diagnostic: also measure with NSHostingView for comparison
            let hostingView = NSHostingView(rootView: bubble)
            hostingView.frame = NSRect(x: 0, y: 0, width: targetWidth, height: 10000)
            hostingView.layoutSubtreeIfNeeded()
            let fittingHeight = hostingView.fittingSize.height
            let intrinsicHeight = hostingView.intrinsicContentSize.height

            let hasVideo = !message.isDeleted && message.modelContext != nil &&
                message.attachments.contains { $0.kind == .video }
            if hasVideo || abs(size.height - fittingHeight) > 5 {
                let attCount = message.attachments.count
                let videoAtt = message.attachments.first { $0.kind == .video }
                let converted = videoAtt?.convertedName ?? "nil"
                let playName = videoAtt?.convertedName ?? videoAtt?.storedName ?? "?"
                let ratio = Coordinator.videoAspectRatio(url: FileStorage.url(for: playName))
                AppLogger.debug("measureRow[\(row)]: sizeThatFits=\(Int(size.height)) fitting=\(Int(fittingHeight)) targetW=\(Int(targetWidth)) atts=\(attCount) converted=\(converted) ratio=\(String(format:"%.2f",ratio)) fontScale=\(fontScale) content='\(message.content.prefix(40))'", category: "table-height")
            }

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

        /// Writes a known aspect ratio into the static cache. Called from VideoPlayerView
        /// when it discovers the real ratio from the converted MP4 (WebM/MKV originals
        /// can't be read by AVAsset, so precomputeVideoAspectRatio fails for them).
        static func setVideoAspectRatio(_ ratio: CGFloat, for url: URL) {
            let key = url.lastPathComponent
            videoAspectRatioCache[key] = ratio
        }

        /// Pre-computes and caches the aspect ratio. Call from a background thread.
        /// The cache write is dispatched to MainActor to avoid data races.
        static func precomputeVideoAspectRatio(url: URL) {
            let key = url.lastPathComponent
            let asset = AVAsset(url: url)
            if let track = asset.tracks(withMediaType: .video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                let w = abs(size.width)
                let h = abs(size.height)
                if w > 0 && h > 0 {
                    let ratio = w / h
                    DispatchQueue.main.async {
                        videoAspectRatioCache[key] = ratio
                    }
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
            guard row < messages.count, !messages[row].isDeleted, messages[row].modelContext != nil else { return }

            if expandedMessages.contains(messageID) {
                expandedMessages.remove(messageID)
            } else {
                expandedMessages.insert(messageID)
            }

            guard let tableView else { return }

            heightCache.removeValue(forKey: messageID)

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
class ChatNSTableView: NSTableView {
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
