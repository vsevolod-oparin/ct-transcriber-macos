import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    let conversation: Conversation
    @Bindable var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            MessageListView(messages: viewModel.sortedMessages(for: conversation),
                            isStreaming: viewModel.isStreaming)

            if let error = viewModel.lastError {
                ErrorBanner(message: error) {
                    viewModel.lastError = nil
                }
            }

            Divider()

            ChatInputBar(viewModel: viewModel, conversation: conversation, isInputFocused: $isInputFocused)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isInputFocused = true
        }
        .navigationTitle(conversation.title)
        .onAppear {
            isInputFocused = true
        }
        .onChange(of: conversation.id) { _, _ in
            isInputFocused = true
        }
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
                .lineLimit(2)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubble(message: message,
                                      isStreamingThis: isStreaming && message == messages.last && message.role == .assistant)
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

private struct MessageBubble: View {
    let message: Message
    var isStreamingThis: Bool = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                ForEach(message.attachments) { attachment in
                    AttachmentView(attachment: attachment)
                }

                if !message.content.isEmpty {
                    HStack(alignment: .bottom, spacing: 4) {
                        Text(message.content)
                            .textSelection(.enabled)

                        if isStreamingThis {
                            ProgressView()
                                .controlSize(.mini)
                                .padding(.bottom, 2)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isUser ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                    .foregroundStyle(isUser ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else if isStreamingThis {
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

                Text(message.timestamp.formatted(.dateTime.hour().minute()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Attachment View

private struct AttachmentView: View {
    let attachment: Attachment

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
