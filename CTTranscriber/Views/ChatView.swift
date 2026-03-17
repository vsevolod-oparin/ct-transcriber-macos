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
            .onChange(of: messages.last?.content) { _, _ in
                if let lastID = messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: messages.count) { _, _ in
                if let lastID = messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Message Bubble

/// Number of lines above which a message is auto-collapsed.
private let collapseThreshold = 15
/// Number of preview lines shown when collapsed.
private let collapsedPreviewLines = 5

private struct MessageBubble: View {
    let message: Message
    var isStreamingThis: Bool = false
    let onRetry: () -> Void
    @State private var isExpanded = false
    @State private var isHovering = false

    private var isUser: Bool { message.role == .user }
    private var isError: Bool {
        message.content.contains("⚠") ||
        message.content.hasPrefix("Transcription failed") ||
        message.content.hasPrefix("Transcription cancelled")
    }
    private var isLong: Bool {
        message.content.components(separatedBy: "\n").count > collapseThreshold
    }

    var body: some View {
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
                    bubbleContent
                        .contextMenu { bubbleContextMenu }
                } else if isStreamingThis {
                    thinkingBubble
                }

                HStack(spacing: 4) {
                    if isError {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }

                    Text(message.timestamp.formatted(.dateTime.hour().minute()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if isError {
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
    }

    @ViewBuilder
    private var copyButton: some View {
        if isHovering && !message.content.isEmpty && !isStreamingThis {
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
        } else {
            // Invisible placeholder to keep layout stable
            Color.clear.frame(width: 16)
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 4) {
                if isLong && !isExpanded && !isStreamingThis {
                    // Collapsed: show preview
                    Text(collapsedPreview)
                        .textSelection(.enabled)
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

            // Collapse/expand toggle
            if isLong && !isStreamingThis {
                Button(isExpanded ? "Show less" : "Show more (\(lineCount) lines)") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(bubbleBackground)
        .foregroundStyle(isUser ? .white : .primary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var bubbleBackground: some ShapeStyle {
        if isError {
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
    private var bubbleContextMenu: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.content, forType: .string)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        // For transcription results, offer copy without timestamps
        if message.content.contains("[") && message.content.contains("→") {
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

        if isError {
            Divider()
            Button { onRetry() } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        }
    }

    private var lineCount: Int {
        message.content.components(separatedBy: "\n").count
    }

    private var collapsedPreview: String {
        let lines = message.content.components(separatedBy: "\n")
        return lines.prefix(collapsedPreviewLines).joined(separator: "\n") + "\n..."
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

            TextField("Message...", text: $viewModel.messageText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused(isInputFocused)
                .disabled(viewModel.isStreaming)
                .onSubmit {
                    if !NSEvent.modifierFlags.contains(.shift) {
                        viewModel.sendMessage()
                    }
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
