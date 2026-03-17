import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct ChatView: View {
    let conversation: Conversation
    @Bindable var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            MessageListView(messages: viewModel.sortedMessages(for: conversation),
                            isStreaming: viewModel.isStreaming,
                            onRetry: { message in viewModel.retryMessage(message, in: conversation) })

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
        .navigationTitle(conversation.title)
        .onAppear {
            isInputFocused = true
        }
        .onChange(of: conversation.id) { _, _ in
            isInputFocused = true
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

// MARK: - Message List

private struct MessageListView: View {
    let messages: [Message]
    let isStreaming: Bool
    let onRetry: (Message) -> Void

    /// Track content length to detect changes without expensive string comparison.
    private var lastContentLength: Int {
        messages.last?.content.count ?? 0
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubble(message: message,
                                      isStreamingThis: isStreaming && message == messages.last && message.role == .assistant,
                                      onRetry: { onRetry(message) })
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: lastContentLength) { _, _ in
                // Only auto-scroll during streaming — avoids scroll jumps when browsing
                if isStreaming {
                    scrollToBottom(proxy: proxy)
                }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastID = messages.last?.id {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
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

private struct MessageBubble: View {
    let message: Message
    var isStreamingThis: Bool = false
    let onRetry: () -> Void
    @State private var isExpanded = false
    @State private var isHovering = false
    @State private var analysis: MessageAnalysis?

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
                    AttachmentView(attachment: attachment)
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
            // Recompute analysis when content changes (e.g., streaming)
            analysis = MessageAnalysis(content: message.content)
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
                // Use NSTextView for large content — SwiftUI Text chokes on big strings
                // Full-height NSTextView — no inner scrolling. The outer chat
                // ScrollView handles navigation.
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
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
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

/// Uses NSTextView for rendering large text content. Scrollable, selectable, performant
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

        // Set the text container width so layout calculates correct height
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
    @State private var isPlaying = false
    @State private var player: AVAudioPlayer?

    var body: some View {
        HStack(spacing: 6) {
            // Play button for audio/video
            if attachment.kind == .audio || attachment.kind == .video {
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
            } else {
                Image(systemName: iconName)
            }

            Text(attachment.originalName)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onDisappear {
            player?.stop()
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player?.stop()
            isPlaying = false
        } else {
            let url = FileStorage.url(for: attachment.storedName)
            do {
                player = try AVAudioPlayer(contentsOf: url)
                player?.play()
                isPlaying = true
            } catch {
                AppLogger.error("Failed to play audio: \(error)", category: "audio")
            }
        }
    }

    private var iconName: String {
        switch attachment.kind {
        case .audio: "waveform"
        case .video: "film"
        case .image: "photo"
        case .text:  "doc.text"
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

