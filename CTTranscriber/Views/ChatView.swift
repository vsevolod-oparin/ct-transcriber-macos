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

            if viewModel.isTranscribingCurrentConversation {
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

// MARK: - Auto Title Button

struct AutoTitleButton: View {
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

// MARK: - Title Rename Field (NSViewRepresentable — stable focus)

/// NSTextField for renaming the conversation title in the toolbar.
/// Uses NSViewRepresentable to avoid SwiftUI re-render focus loss.
struct TitleRenameField: NSViewRepresentable {
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
