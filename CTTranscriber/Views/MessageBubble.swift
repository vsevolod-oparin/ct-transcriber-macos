import SwiftUI
import UniformTypeIdentifiers

// MARK: - Message Content Analysis (computed once, cached)

/// Pre-analyzed message metadata to avoid recomputing on every render.
struct MessageAnalysis {
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

    private static func analyze(content: String, isError: Bool) -> (lineCount: Int, lineCountDisplay: String, isLong: Bool, hasTimestamps: Bool, collapsedPreview: String) {
        let timestampSample = content.prefix(500)
        let hasTimestamps = timestampSample.contains("[") && timestampSample.contains("\u{2192}")

        let utf8 = content.utf8
        let totalBytes = utf8.count

        let lineCount: Int
        let lineCountDisplay: String
        if totalBytes <= lineCountSampleSize {
            var count = 1
            for byte in utf8 {
                if byte == UInt8(ascii: "\n") { count += 1 }
            }
            lineCount = count
            lineCountDisplay = "\(count)"
        } else {
            var newlines = 0
            var scanned = 0
            for byte in utf8 {
                if byte == UInt8(ascii: "\n") { newlines += 1 }
                scanned += 1
                if scanned >= lineCountSampleSize { break }
            }
            let estimated = Int(Double(newlines) / Double(scanned) * Double(totalBytes)) + 1
            lineCount = estimated
            lineCountDisplay = "~\(estimated)"
        }
        let isLong = lineCount > collapseThreshold

        let collapsedPreview: String
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

        return (lineCount, lineCountDisplay, isLong, hasTimestamps, collapsedPreview)
    }

    init(message: Message) {
        let content = message.content
        isError = message.lifecycle == .errorLLM ||
                  message.lifecycle == .errorTranscription ||
                  message.lifecycle == .cancelled

        let result = Self.analyze(content: content, isError: isError)
        lineCount = result.lineCount
        lineCountDisplay = result.lineCountDisplay
        isLong = result.isLong
        hasTimestamps = result.hasTimestamps
        collapsedPreview = result.collapsedPreview
    }

    init(content: String) {
        let prefix100 = content.prefix(100)
        isError = prefix100.contains("\u{26A0}") ||
                  prefix100.hasPrefix("Transcription cancelled")

        let result = Self.analyze(content: content, isError: isError)
        lineCount = result.lineCount
        lineCountDisplay = result.lineCountDisplay
        isLong = result.isLong
        hasTimestamps = result.hasTimestamps
        collapsedPreview = result.collapsedPreview
    }
}

// MARK: - Message Bubble

/// A single chat message bubble. Used both for display (in NSTableView cells)
/// and for height measurement (in the coordinator).
///
/// `isExpanded` is managed externally by the table coordinator's `expandedMessages` set
/// so that expansion state survives cell reuse.
struct MessageBubble: View {
    let message: Message
    var isStreamingThis: Bool = false
    var isExpanded: Bool = false
    var renderMarkdown: Bool = true
    let onRetry: () -> Void
    let onCollapseToggle: () -> Void
    @Binding var seekRequest: (id: UUID, storedName: String, time: TimeInterval)?
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
        analysis ?? MessageAnalysis(message: message)
    }

    var body: some View {
        let info = currentAnalysis

        HStack(alignment: .top, spacing: sp(4)) {
            if isUser {
                Spacer(minLength: sp(100))
                actionButtons(info: info)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: sp(4)) {
                ForEach(message.attachments.filter { !$0.isDeleted && $0.modelContext != nil }) { attachment in
                    AttachmentView(attachment: attachment, seekRequest: $seekRequest)
                }

                if !message.content.isEmpty {
                    bubbleContent(info: info)
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
                actionButtons(info: info)
                Spacer(minLength: sp(100))
            }
        }
        .onHover { isHovering = $0 }
        .task(id: message.content.count) {
            // Throttle analysis recomputation during streaming
            let currentLength = message.content.count
            let delta = abs(currentLength - lastAnalyzedLength)
            if analysis == nil || !isStreamingThis || delta >= Self.analysisRecomputeThrottle {
                analysis = MessageAnalysis(message: message)
                lastAnalyzedLength = currentLength
            }
        }
    }

    @ViewBuilder
    private func actionButtons(info: MessageAnalysis) -> some View {
        VStack(spacing: 2) {
            copyButton
            if info.hasTimestamps {
                srtExportButton
            }
        }
    }

    @ViewBuilder
    private var srtExportButton: some View {
        Button {
            exportAsSRT(content: message.content)
        } label: {
            Image(systemName: "square.and.arrow.down")
                .font(sf.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Export as SRT")
        .opacity(isHovering && !message.content.isEmpty && !isStreamingThis ? 1 : 0)
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
            if info.isLong && !isExpanded && !isStreamingThis && info.hasTimestamps,
               let audioName = findAudioAttachment() {
                TranscriptTextView(
                    content: info.collapsedPreview,
                    audioStoredName: audioName,
                    seekRequest: $seekRequest,
                    fontSize: CGFloat(NSFont.systemFontSize) * CGFloat(fontScale),
                    textColor: isUser ? .white : .labelColor
                )
            } else if info.isLong && !isExpanded && !isStreamingThis {
                Text(info.collapsedPreview)
                    .textSelection(.enabled)
            } else if info.hasTimestamps && !isStreamingThis, let audioName = findAudioAttachment() {
                TranscriptTextView(
                    content: message.content,
                    audioStoredName: audioName,
                    seekRequest: $seekRequest,
                    fontSize: CGFloat(NSFont.systemFontSize) * CGFloat(fontScale),
                    textColor: isUser ? .white : .labelColor
                )
            } else if message.content.count > largeTextThreshold && !isStreamingThis {
                LargeTextView(text: message.content, textColor: isUser ? .white : .labelColor,
                              fontSize: CGFloat(NSFont.systemFontSize) * CGFloat(fontScale))
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    if !isUser && !isStreamingThis && renderMarkdown {
                        MarkdownContentView(
                            content: message.content,
                            fontSize: CGFloat(NSFont.systemFontSize) * CGFloat(fontScale)
                        )
                    } else {
                        Text(message.content)
                            .textSelection(.enabled)
                    }

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
        .padding(.horizontal, sp(14))
        .padding(.vertical, sp(10))
        .background(bubbleBackground(info: info))
        .foregroundStyle(isUser ? .white : .primary)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: isUser ? .clear : .black.opacity(0.06), radius: 3, x: 0, y: 1)
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
                        seekRequest = (id: UUID(), storedName: audioName, time: firstTimestamp)
                    }
                } label: {
                    Label("Play from \(formatSeekTime(firstTimestamp))", systemImage: "play.fill")
                }
            }
        }

        if info.hasTimestamps {
            Button {
                exportAsSRT(content: message.content)
            } label: {
                Label("Export as SRT...", systemImage: "doc.text")
            }

            Button {
                exportAsText(content: message.content)
            } label: {
                Label("Export as Text...", systemImage: "doc.plaintext")
            }

            Button {
                exportAsMarkdown(content: message.content)
            } label: {
                Label("Export as Markdown...", systemImage: "doc.richtext")
            }
        }

        if info.isError {
            Divider()
            Button { onRetry() } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        }
    }

    private func exportAsSRT(content: String) {
        let lines = content.split(separator: "\n")
        var srt = ""
        var index = 1

        for line in lines {
            let str = String(line)
            // Parse lines like "[0:00 → 0:05] Hello there"
            guard str.hasPrefix("["),
                  let bracketEnd = str.firstIndex(of: "]"),
                  let arrow = str.range(of: " \u{2192} ") else { continue }

            let startStr = String(str[str.index(after: str.startIndex)..<arrow.lowerBound])
            let endStr = String(str[arrow.upperBound..<bracketEnd])
            let text = String(str[str.index(after: bracketEnd)...]).trimmingCharacters(in: .whitespaces)

            let startSRT = toSRTTimestamp(startStr)
            let endSRT = toSRTTimestamp(endStr)

            srt += "\(index)\n\(startSRT) --> \(endSRT)\n\(text)\n\n"
            index += 1
        }

        guard !srt.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "srt")!]
        // Derive SRT filename from the audio attachment's original name
        var srtName = "transcript.srt"
        if let _ = findAudioAttachment() {
            // findAudioAttachment returns storedName; get originalName from prev message
            if let conversation = message.conversation {
                let sorted = conversation.messages.sorted { $0.timestamp < $1.timestamp }
                if let myIndex = sorted.firstIndex(where: { $0.id == message.id }), myIndex > 0 {
                    let prev = sorted[myIndex - 1]
                    if let att = prev.attachments.first(where: { $0.kind == .audio || $0.kind == .video }) {
                        let baseName = (att.originalName as NSString).deletingPathExtension
                        srtName = "\(baseName).srt"
                    }
                }
            }
        }
        panel.nameFieldStringValue = srtName
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try srt.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    private func exportAsText(content: String) {
        let plain = content.split(separator: "\n").map { line in
            let str = String(line)
            if let bracket = str.range(of: "] ") {
                return String(str[bracket.upperBound...])
            }
            return str
        }.joined(separator: "\n")

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = deriveExportFilename(extension: "txt")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try plain.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    private func exportAsMarkdown(content: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = deriveExportFilename(extension: "md")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// Derives an export filename from the audio attachment's original name in the previous message.
    private func deriveExportFilename(extension ext: String) -> String {
        if let conversation = message.conversation {
            let sorted = conversation.messages.sorted { $0.timestamp < $1.timestamp }
            if let myIndex = sorted.firstIndex(where: { $0.id == message.id }), myIndex > 0 {
                let prev = sorted[myIndex - 1]
                if let att = prev.attachments.first(where: { $0.kind == .audio || $0.kind == .video }) {
                    let baseName = (att.originalName as NSString).deletingPathExtension
                    return "\(baseName).\(ext)"
                }
            }
        }
        return "transcript.\(ext)"
    }

    /// Converts "m:ss" or "h:mm:ss" to SRT format "HH:MM:SS,000"
    private func toSRTTimestamp(_ ts: String) -> String {
        let parts = ts.split(separator: ":").compactMap { Int($0) }
        let h: Int, m: Int, s: Int
        switch parts.count {
        case 2: h = 0; m = parts[0]; s = parts[1]
        case 3: h = parts[0]; m = parts[1]; s = parts[2]
        default: h = 0; m = 0; s = 0
        }
        return String(format: "%02d:%02d:%02d,000", h, m, s)
    }

    /// Parses the first `[MM:SS` or `[SS.SS` timestamp from transcript text.
    private func parseFirstTimestamp(from text: String) -> TimeInterval? {
        // Match [0.00 → or [1:23.45 →
        guard let bracketRange = text.range(of: "[") else { return nil }
        let afterBracket = text[bracketRange.upperBound...]
        guard let arrowRange = afterBracket.range(of: " \u{2192}") ?? afterBracket.range(of: "\u{2192}") else { return nil }
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

// MARK: - Transcript Text View (NSTextView with clickable timestamps + text selection)

/// NSTextView-based transcript renderer with clickable timestamp lines.
/// Click handling uses line-number detection (not NSTextView links) to avoid
/// coordinate offset issues in the NSHostingView → NSTableView embedding.
struct TranscriptTextView: NSViewRepresentable {
    let content: String
    let audioStoredName: String
    @Binding var seekRequest: (id: UUID, storedName: String, time: TimeInterval)?
    let fontSize: CGFloat
    let textColor: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> TranscriptNSTextView {
        let textView = TranscriptNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.coordinator = context.coordinator
        return textView
    }

    func updateNSView(_ textView: TranscriptNSTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.lineTimestamps = parseLineTimestamps()
        let currentLen = textView.textStorage?.length ?? 0
        if currentLen != content.count {
            textView.textStorage?.setAttributedString(buildAttributedString())
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: TranscriptNSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let usedRect = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
        let height = usedRect.height + textView.textContainerInset.height * 2
        return CGSize(width: width, height: height)
    }

    /// Parse timestamps per source line (index in the original content).
    private func parseLineTimestamps() -> [Int: TimeInterval] {
        var result: [Int: TimeInterval] = [:]
        let lines = content.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let str = line.trimmingCharacters(in: .whitespaces)
            guard str.hasPrefix("["),
                  let arrowRange = str.range(of: " \u{2192} ") ?? str.range(of: "\u{2192}") else { continue }
            let timeStr = String(str[str.index(after: str.startIndex)..<arrowRange.lowerBound])
            if let time = parseTimestamp(timeStr) {
                result[i] = time
            }
        }
        return result
    }

    private func buildAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: fontSize)
        let timestampFont = NSFont.monospacedSystemFont(ofSize: fontSize * 0.9, weight: .regular)
        let timestampColor = NSColor.secondaryLabelColor
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: textColor]

        let lines = content.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let str = line.trimmingCharacters(in: .whitespaces)

            if str.hasPrefix("["),
               let bracketEnd = str.firstIndex(of: "]"),
               str.contains("\u{2192}") {
                let bracketContent = String(str[str.startIndex...bracketEnd])
                let afterBracket = String(str[str.index(after: bracketEnd)...])
                let tsAttrs: [NSAttributedString.Key: Any] = [.font: timestampFont, .foregroundColor: timestampColor]
                result.append(NSAttributedString(string: bracketContent, attributes: tsAttrs))
                result.append(NSAttributedString(string: afterBracket, attributes: bodyAttrs))
            } else {
                result.append(NSAttributedString(string: str, attributes: bodyAttrs))
            }

            if i < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: bodyAttrs))
            }
        }
        return result
    }

    private func parseTimestamp(_ str: String) -> TimeInterval? {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":")
        if parts.count == 2 {
            guard let min = Double(parts[0]), let sec = Double(parts[1]) else { return nil }
            return min * 60 + sec
        } else if parts.count == 1 {
            return Double(trimmed)
        }
        return nil
    }

    @MainActor
    class Coordinator {
        var parent: TranscriptTextView
        var lineTimestamps: [Int: TimeInterval] = [:]

        init(_ parent: TranscriptTextView) {
            self.parent = parent
        }

        func handleClick(at point: NSPoint, in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            // Convert click point to text container coordinates
            let containerOrigin = textView.textContainerOrigin
            let pointInContainer = NSPoint(x: point.x - containerOrigin.x, y: point.y - containerOrigin.y)

            // Find the character index at this point
            let charIndex = layoutManager.characterIndex(
                for: pointInContainer,
                in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )

            // Find which source line this character belongs to
            let fullText = textView.string
            let prefix = fullText.prefix(charIndex)
            let sourceLine = prefix.filter({ $0 == "\n" }).count

            if let time = lineTimestamps[sourceLine] {
                let mgr = AudioPlaybackManager.shared
                if mgr.currentlyPlayingID == parent.audioStoredName {
                    mgr.seek(to: time)
                    if !mgr.isPlaying {
                        mgr.togglePlayPause()
                    }
                } else {
                    parent.seekRequest = (id: UUID(), storedName: parent.audioStoredName, time: time)
                }
            }
        }
    }
}

/// Custom NSTextView that detects single clicks on timestamp lines.
/// Uses line-number based detection instead of NSTextView link attributes
/// to avoid coordinate offset issues in NSHostingView embedding.
class TranscriptNSTextView: NSTextView {
    var coordinator: TranscriptTextView.Coordinator?

    override func mouseDown(with event: NSEvent) {
        let clickCount = event.clickCount
        let point = convert(event.locationInWindow, from: nil)

        // Single click on a timestamp line → seek
        if clickCount == 1 {
            coordinator?.handleClick(at: point, in: self)
        }

        // Always pass through for selection handling
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Large Text View (NSTextView for performance with big strings)

/// Uses NSTextView for rendering large text content. Selectable, performant
/// even with hundreds of thousands of characters — unlike SwiftUI Text which freezes.
struct LargeTextView: NSViewRepresentable {
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
