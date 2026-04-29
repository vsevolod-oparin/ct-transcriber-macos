import SwiftUI

struct ConversationListView: View {
    @Bindable var viewModel: ChatViewModel
    @State private var editingConversationID: UUID?
    @State private var editingTitle: String = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(viewModel.filteredConversations) { conversation in
                    ConversationRow(
                        conversation: conversation,
                        isHighlighted: viewModel.highlightedIDs.contains(conversation.id),
                        isActive: viewModel.selectedConversationID == conversation.id,
                        isEditing: editingConversationID == conversation.id,
                        editingTitle: $editingTitle,
                        onCommitRename: { commitRename(conversation) },
                        onCancelRename: { cancelRename() }
                    )
                    .tag(conversation.id)
                    .id(conversation.id)
                    .listRowBackground(rowBackground(for: conversation))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded {
                        // Don't process clicks while renaming — would steal focus from text field
                        guard editingConversationID == nil else { return }

                        let clickCount = NSApp.currentEvent?.clickCount ?? 1

                        // Double-click on an already-selected conversation = rename
                        if clickCount >= 2 && viewModel.selectedConversationID == conversation.id {
                            beginRename(conversation)
                            return
                        }

                        if NSEvent.modifierFlags.contains(.command) {
                            if viewModel.highlightedIDs.contains(conversation.id) {
                                viewModel.highlightedIDs.remove(conversation.id)
                            } else {
                                viewModel.highlightedIDs.insert(conversation.id)
                            }
                            viewModel.setCursor(to: conversation.id)
                        } else if NSEvent.modifierFlags.contains(.shift) {
                            extendHighlight(to: conversation)
                        } else {
                            viewModel.highlightedIDs = [conversation.id]
                            viewModel.setCursor(to: conversation.id)
                            viewModel.selectedConversationID = conversation.id
                            // Keep sidebar focused after click — the detail view swap
                            // can steal first responder, so reclaim it.
                            DispatchQueue.main.async {
                                if let window = NSApp.keyWindow,
                                   let sidebarView = Self.findOutlineView(in: window.contentView) {
                                    window.makeFirstResponder(sidebarView)
                                }
                            }
                        }
                    })
                    .contextMenu {
                        Button {
                            beginRename(conversation)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Divider()
                        Button {
                            viewModel.exportConversationJSON(conversation)
                        } label: {
                            Label("Export as JSON...", systemImage: "arrow.down.doc")
                        }
                        Button {
                            viewModel.exportConversationMarkdown(conversation)
                        } label: {
                            Label("Export as Markdown...", systemImage: "doc.richtext")
                        }
                        Button {
                            viewModel.exportConversationPDF(conversation)
                        } label: {
                            Label("Export as PDF...", systemImage: "doc.text")
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
            .overlay {
                if viewModel.filteredConversations.isEmpty {
                    VStack(spacing: 8) {
                        if viewModel.searchText.isEmpty {
                            Text("No conversations")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("Press ⌘N to start")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text("No results")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $viewModel.searchText, prompt: "Search conversations")
            .listStyle(.sidebar)
            .onChange(of: viewModel.highlightedIDs) { _, newIDs in
                // Only cancel rename if highlighting moved AWAY from the editing conversation
                if let editingID = editingConversationID, !newIDs.contains(editingID) {
                    cancelRename()
                }
                // Scroll to the cursor position
                if viewModel.highlightCursor < viewModel.conversations.count {
                    let cursorID = viewModel.conversations[viewModel.highlightCursor].id
                    withAnimation {
                        proxy.scrollTo(cursorID, anchor: nil)
                    }
                }
            }
            .onChange(of: viewModel.selectedConversationID) { _, newID in
                if let newID {
                    DispatchQueue.main.async {
                        withAnimation {
                            proxy.scrollTo(newID)
                        }
                    }
                }
            }
            .onKeyPress(keys: [.upArrow], phases: .down) { keyPress in
                guard editingConversationID == nil else { return .ignored }
                if keyPress.modifiers.contains(.command) {
                    viewModel.scrollToTop()
                    return .handled
                }
                viewModel.moveHighlight(direction: -1, extend: keyPress.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(keys: [.downArrow], phases: .down) { keyPress in
                guard editingConversationID == nil else { return .ignored }
                if keyPress.modifiers.contains(.command) {
                    viewModel.scrollToBottom()
                    return .handled
                }
                viewModel.moveHighlight(direction: 1, extend: keyPress.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.return) {
                guard editingConversationID == nil else { return .ignored }
                viewModel.activateHighlighted()
                return .handled
            }
            // Backspace key = \u{7F} on macOS (physical backspace sends ASCII DEL)
            .onKeyPress(characters: CharacterSet(charactersIn: "\u{7F}\u{08}")) { _ in
                guard editingConversationID == nil else { return .ignored }
                if !viewModel.highlightedIDs.isEmpty {
                    showDeleteConfirmation = true
                }
                return .handled
            }
        }
        .accessibilityIdentifier("conversationList")
        .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        .toolbar {
            ToolbarItem {
                Button(action: viewModel.createConversation) {
                    Label("New Conversation", systemImage: "plus")
                }
                .accessibilityIdentifier("newConversationButton")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .alert("Delete Conversation\(viewModel.highlightedIDs.count > 1 ? "s" : "")?",
               isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                viewModel.deleteHighlightedConversations()
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            let count = viewModel.highlightedIDs.count
            if count == 1 {
                Text("This conversation and all its messages will be permanently deleted.")
            } else {
                Text("\(count) conversations and all their messages will be permanently deleted.")
            }
        }
    }

    // MARK: - Row Background

    private func rowBackground(for conversation: Conversation) -> some View {
        let isHighlighted = viewModel.highlightedIDs.contains(conversation.id)
        let isActive = viewModel.selectedConversationID == conversation.id

        return Group {
            if isHighlighted && isActive {
                Color.accentColor.opacity(0.3)
            } else if isHighlighted {
                Color.accentColor.opacity(0.15)
            } else if isActive {
                Color.accentColor.opacity(0.08)
            } else {
                Color.clear
            }
        }
    }

    // MARK: - Shift+Click Range Extension

    private func extendHighlight(to conversation: Conversation) {
        guard let targetIdx = viewModel.conversations.firstIndex(where: { $0.id == conversation.id }) else {
            return
        }
        let anchorIdx = min(viewModel.highlightCursor, viewModel.conversations.count - 1)
        let range = min(anchorIdx, targetIdx)...max(anchorIdx, targetIdx)
        viewModel.highlightedIDs = Set(viewModel.conversations[range].map(\.id))
    }

    // MARK: - Focus Helper

    static func findOutlineView(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is NSOutlineView { return view }
        for subview in view.subviews {
            if let found = findOutlineView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Rename

    private func beginRename(_ conversation: Conversation) {
        guard !conversation.isDeleted, conversation.modelContext != nil else { return }
        editingTitle = conversation.title
        editingConversationID = conversation.id
    }

    private func commitRename(_ conversation: Conversation) {
        guard !conversation.isDeleted, conversation.modelContext != nil else {
            editingConversationID = nil
            return
        }
        let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLogger.info("commitRename: editingTitle='\(editingTitle)' trimmed='\(trimmed)' convo='\(conversation.title)'", category: "rename")
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
    let isHighlighted: Bool
    let isActive: Bool
    let isEditing: Bool
    @Binding var editingTitle: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    @Environment(\.fontScale) private var fontScale

    var body: some View {
        let sf = ScaledFont(scale: fontScale)
        if conversation.isDeleted || conversation.modelContext == nil {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    SelectAllTextField(text: $editingTitle, onCommit: onCommitRename, onCancel: onCancelRename)
                        .font(sf.subheadline.weight(.semibold))
                        .accessibilityIdentifier("renameTextField")
                } else {
                    HStack(spacing: 2) {
                        Text(conversation.title)
                            .font(sf.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .accessibilityIdentifier("conversationTitle_\(conversation.title)")
                }

                Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                    .font(sf.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .accessibilityIdentifier("conversationRow_\(conversation.title)")
        }
    }
}

// MARK: - TextField that selects all text on appear

private struct SelectAllTextField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void
    @Environment(\.fontScale) private var fontScale

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: CGFloat(NSFont.systemFontSize) * CGFloat(fontScale), weight: .semibold)
        field.setAccessibilityIdentifier("renameField")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.font = .systemFont(ofSize: CGFloat(NSFont.systemFontSize) * CGFloat(fontScale), weight: .semibold)
        field.stringValue = text

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
        var focusEstablished = false

        init(_ parent: SelectAllTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                AppLogger.debug("controlTextDidChange: '\(field.stringValue)'", category: "rename")
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

