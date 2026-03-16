import SwiftUI

struct ConversationListView: View {
    @Bindable var viewModel: ChatViewModel
    @State private var editingConversationID: UUID?
    @State private var editingTitle: String = ""

    var body: some View {
        List(selection: $viewModel.selectedConversationID) {
            ForEach(viewModel.conversations) { conversation in
                ConversationRow(
                    conversation: conversation,
                    isEditing: editingConversationID == conversation.id,
                    editingTitle: $editingTitle,
                    onCommitRename: { commitRename(conversation) },
                    onCancelRename: { cancelRename() },
                    onDoubleClick: { beginRename(conversation) }
                )
                .tag(conversation.id)
                .contextMenu {
                    Button {
                        beginRename(conversation)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        viewModel.deleteConversation(conversation)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .onChange(of: viewModel.selectedConversationID) { _, newID in
            if editingConversationID != nil && editingConversationID != newID {
                cancelRename()
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        .toolbar {
            ToolbarItem {
                Button(action: viewModel.createConversation) {
                    Label("New Conversation", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    private func beginRename(_ conversation: Conversation) {
        editingTitle = conversation.title
        editingConversationID = conversation.id
    }

    private func commitRename(_ conversation: Conversation) {
        let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            viewModel.renameConversation(conversation, to: trimmed)
        }
        editingConversationID = nil
    }

    private func cancelRename() {
        editingConversationID = nil
    }
}

// MARK: - Conversation Row

private struct ConversationRow: View {
    let conversation: Conversation
    let isEditing: Bool
    @Binding var editingTitle: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDoubleClick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing {
                SelectAllTextField(text: $editingTitle, onCommit: onCommitRename, onCancel: onCancelRename)
                    .font(.headline)
            } else {
                Text(conversation.title)
                    .font(.headline)
                    .lineLimit(1)
            }

            Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .overlay {
            if !isEditing {
                DoubleClickOverlay(onDoubleClick: onDoubleClick)
            }
        }
    }
}

// MARK: - AppKit double-click detector (doesn't interfere with List selection)

private struct DoubleClickOverlay: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DoubleClickView {
        let view = DoubleClickView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: DoubleClickView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }

    class DoubleClickView: NSView {
        var onDoubleClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if event.clickCount == 2 {
                onDoubleClick?()
            }
        }
    }
}

// MARK: - TextField that selects all text on appear

private struct SelectAllTextField: NSViewRepresentable {
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
        field.stringValue = text

        // Select all on first appear
        if !context.coordinator.didFocus {
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
        let parent: SelectAllTextField
        var didFocus = false
        var didFinish = false
        /// True once the field has actually received focus. Until then,
        /// focus-loss events are spurious (caused by the view swap during
        /// double-click) and should be ignored.
        var focusEstablished = false

        init(_ parent: SelectAllTextField) {
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
