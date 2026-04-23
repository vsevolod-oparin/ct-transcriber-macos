import SwiftUI
import UniformTypeIdentifiers

// MARK: - Input Bar

let attachableContentTypes: [UTType] = [
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
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .focused(isInputFocused)
                .disabled(viewModel.isStreamingCurrentConversation)
                .overlay(alignment: .topLeading) {
                    if viewModel.messageText.isEmpty {
                        Text("Message...")
                            .font(sf.body)
                            .foregroundStyle(.placeholder)
                            .allowsHitTesting(false)
                            .padding(.leading, 13)
                            .padding(.top, 6)
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
        .padding(.init(top: 10, leading: 14, bottom: 12, trailing: 14))
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}
