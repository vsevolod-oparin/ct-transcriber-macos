# Milestone 1: Chat UI Shell (No Backend)

**Date:** 2026-03-16
**Status:** Complete

---

## What Was Done

### Views Created

**`ContentView.swift`** — Root view
- `NavigationSplitView` with `columnVisibility` binding (sidebar collapsible)
- Routes to `ChatView` when conversation selected, `ContentUnavailableView` when not
- Min window size: 700x500

**`ConversationListView.swift`** — Sidebar
- `List` with selection binding to `viewModel.selectedConversationID`
- Each row shows title + relative date ("2 days ago")
- Right-click context menu with Delete action
- Toolbar "+" button for new conversation (`Cmd+N` shortcut)

**`ChatView.swift`** — Main chat area
- `MessageListView`: `ScrollView` + `LazyVStack` with auto-scroll on new messages
- `MessageBubble`: User messages right-aligned (accent color), assistant left-aligned (control background). Text selectable. Shows timestamp and optional audio file label.
- `ChatInputBar`: Paperclip button (file importer for `.audio` UTType, non-functional placeholder), multiline `TextField` (1-5 lines), send button (arrow.up.circle.fill). Send on Enter, disabled when empty.

### View Model

**`ChatViewModel.swift`** — `@Observable` class
- In-memory `conversations` array with 3 mock conversations (seeded with realistic messages)
- `selectedConversationID` for List selection binding
- `createConversation()`: inserts at top, auto-selects
- `deleteConversation()`: removes, selects next available
- `sendMessage()`: appends user message, updates timestamp, moves conversation to top, clears input

### Key Decisions
- **`@Observable` over `ObservableObject`**: Modern Swift 5.9+ observation — finer-grained updates, no `@Published` needed
- **`@Bindable` for view model**: Required for two-way bindings (text field, selection) with `@Observable`
- **Mock data in ViewModel init**: 3 conversations with varied message counts and dates — enough to test all UI states
- **No SwiftData queries yet**: M1 is purely in-memory; SwiftData wiring is M2's scope. The `modelContainer` in the app is kept for forward-compatibility but the view model doesn't use it.
- **File importer with `.audio` UTType**: Placeholder that opens a file picker but does nothing with the result — ready for M7 to wire up.

---

## Test Criteria Results

| Criteria | Result |
|----------|--------|
| Sidebar shows mock conversations; selecting one displays messages | PASS |
| Sidebar can be collapsed/shown via toolbar button | PASS (NavigationSplitView built-in) |
| Typing text and pressing Send adds a user bubble to the chat | PASS |
| New conversation creates an entry in sidebar | PASS (Cmd+N or + button) |
| Delete conversation removes it from sidebar | PASS (right-click → Delete) |

---

## UI Tests

`CTTranscriberUITests/ConversationRenameUITests.swift` — 3 XCUITest cases:
- `testRenameViaContextMenu` — right-click → Rename → type → Enter → title updated
- `testRenameCancelViaEscape` — right-click → Rename → type → Escape → original title kept
- `testRenameEmptyStringKeepsOriginal` — right-click → Rename → clear → Enter → original title kept

Key findings during test development:
- NSViewRepresentable `SelectAllTextField` inherits the parent VStack's accessibility identifier, not its own `setAccessibilityIdentifier`. Query by `sidebar.textFields.firstMatch` instead.
- The original `DoubleClickOverlay` (NSView with `mouseDown` override) blocked the main run loop when XCUITest inspected the accessibility tree. Replaced with `NSEvent.addLocalMonitorForEvents` approach.
- SwiftUI `List` on macOS is accessible via `app.descendants(matching: .any)["conversationList"]`, not `app.tables` or `app.outlines`.
- App uses `--uitesting` launch argument → in-memory SwiftData container for test isolation.

## Files Created/Modified

- **Created:** `ViewModels/ChatViewModel.swift`, `Views/ConversationListView.swift`, `Views/ChatView.swift`, `CTTranscriberUITests/ConversationRenameUITests.swift`
- **Modified:** `Views/ContentView.swift` (replaced stub with full NavigationSplitView wiring), `App/CTTranscriberApp.swift` (in-memory store for UI testing), `project.yml` (added UI test target)
- **Regenerated:** `CTTranscriber.xcodeproj` (via xcodegen)
