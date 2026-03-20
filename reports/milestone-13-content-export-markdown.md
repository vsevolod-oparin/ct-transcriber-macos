# Milestone 13: Content Export & Markdown

**Date:** 2026-03-20
**Version:** 0.3.1 → 0.3.2
**Status:** Complete

---

## Markdown Rendering

### Implementation

Custom segment-based parser + native SwiftUI rendering. No third-party dependencies.

**Parser** (`MarkdownContentView.swift`):
- Splits message content line-by-line into `MarkdownSegment` enum: `.text`, `.codeBlock`, `.header`, `.table`
- Fenced code blocks (``` with optional language tag)
- Headers (`#` through `######`)
- Tables (lines with `|` separators, separator row detection)
- List normalization: `- `, `* `, `+ ` → `•`; nested indent via non-breaking spaces
- `<br>` tag handling (replaced with `\n` at render time, not at parse time)

**Rendering** (`MarkdownContentView`):
- Text segments → `Text(AttributedString(markdown:, interpretedSyntax: .inlineOnlyPreservingWhitespace))` for bold, italic, strikethrough, inline code, links
- Code blocks → `CodeBlockView` with monospaced font, dark background, copy button with "Copied" feedback
- Headers → scaled font sizes (1.6x–0.95x base)
- Tables → `TableView` with bold header row, divider, aligned cells with inline markdown

**Performance:** Parsed segments cached via `@State` + `.task(id: content.count)`. Only re-parsed when content length changes.

**Scope:** Assistant messages only. User messages, streaming, collapsed previews, large text (>5000 chars), and errors render as plain text.

### Per-Conversation Toggle

- `Conversation.renderMarkdown: Bool?` — SwiftData property (optional for migration safety, `nil` = on)
- Toolbar button with `text.badge.checkmark` / `text.badge.xmark` icon
- Each conversation remembers its preference
- Propagated through `ChatTableView` → `Coordinator` → `MessageBubble` via `renderMarkdown: Bool` parameter
- Height cache invalidated and table reloaded on toggle

---

## Downloadable Media

### Attachment Context Menu

Right-click any attachment (audio, video, image, text):
- **Save As...** — NSSavePanel, copies file with original filename
- **Reveal in Finder** — NSWorkspace.selectFile

### Transcription Export

Right-click transcription message bubble (context menu):
- **Export as SRT...** — subtitle format (pre-existing)
- **Export as Text...** — timestamps stripped, plain text
- **Export as Markdown...** — raw content as .md file

---

## Conversation Export / Import

### Export Formats

| Format | Menu Item | Shortcut | Description |
|--------|-----------|----------|-------------|
| PDF | Export Conversation as PDF | Cmd+E | Formatted with headers, roles, timestamps, code blocks, **real tables via NSTextTable**, inline markdown |
| JSON | Export Conversation as JSON | Cmd+Shift+E | Machine-readable, ISO 8601 dates, messages + metadata (no binary attachments) |
| Markdown | Export Conversation as Markdown | — | Human-readable with role headers, attachment badges, raw content |
| ZIP | Export All Conversations | — | Bulk export: all conversations as individual JSON files in a ZIP (via `/usr/bin/ditto`) |

### Import

| Action | Shortcut | Description |
|--------|----------|-------------|
| Import Conversation | Cmd+Shift+I | Opens JSON file, creates new conversation with all messages and metadata |

### Access Points

- **File menu** — all export/import options
- **Conversation sidebar context menu** — Export as JSON / Markdown / PDF per conversation
- **Message bubble context menu** — transcription export (SRT, Text, Markdown)
- **Attachment context menu** — Save As, Reveal in Finder

### PDF Export Details

- Uses `NSTextView.dataWithPDF(inside:)` for native PDF generation
- Title rendered at 18pt bold
- Role headers with timestamps in secondary color
- Attachment badges with 📎 icon
- Code blocks in monospaced font with `controlBackgroundColor`
- Headers at scaled bold sizes (18/16/14/13pt for h1-h4)
- Inline markdown (bold, italic, links) via `AttributedString(markdown:)` → `NSAttributedString` with font trait preservation
- **Tables rendered with `NSTextTable` + `NSTextTableBlock`** — real grid cells with 0.5pt borders, 4pt padding, header row with background color, auto-sizing for multi-line cells
- `<br>` tags converted to newlines
- Separator lines between messages

### Data Model

```swift
struct ExportedConversation: Codable {
    let id: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let messages: [ExportedMessage]
}

struct ExportedMessage: Codable {
    let id: String
    let role: String
    let content: String
    let timestamp: Date
    let attachments: [ExportedAttachment]
}
```

Import creates a new `Conversation` with `Message` objects. Attachment metadata is preserved but binary files are not included (by design — keeps exports lightweight).

---

## Files Created

| File | Purpose |
|------|---------|
| `CTTranscriber/Views/MarkdownContentView.swift` | Parser, MarkdownContentView, CodeBlockView, TableView |
| `CTTranscriber/Services/ConversationExporter.swift` | JSON/Markdown/PDF export, JSON import, bulk ZIP |

## Files Modified

| File | Changes |
|------|---------|
| `MessageBubble.swift` | Routes assistant messages through MarkdownContentView; added text/markdown export to context menu |
| `ChatTableView.swift` | `renderMarkdown` parameter propagated through coordinator to cells and height measurement |
| `ChatView.swift` | Markdown toggle toolbar button; passes `conversation.renderMarkdown` to ChatTableView |
| `ChatViewModel.swift` | Export/import methods (JSON, Markdown, PDF, bulk ZIP, import) |
| `CTTranscriberApp.swift` | File menu commands with shortcuts; notification names |
| `ContentView.swift` | Refactored into smaller pieces; wired export/import notifications via ViewModifier |
| `ConversationListView.swift` | Export options in conversation context menu |
| `AttachmentView.swift` | Save As / Reveal in Finder context menu |
| `Conversation.swift` | `renderMarkdown: Bool?` property |
| `AppSettings.swift` | Removed global `renderMarkdown` (now per-conversation) |
| `SettingsView.swift` | Removed global markdown toggle |

---

## ROADMAP Checklist

**Downloadable media:**
- [x] "Save As..." context menu on audio, video, and image attachments
- [x] Export transcription text as `.txt`, `.srt`, `.md`
- [x] Drag attachment out of the app to Finder (via `.onDrag` with NSItemProvider)

**Markdown preview:**
- [x] Render markdown in assistant messages (bold, italic, code blocks, lists, headers)
- [x] Option to toggle between raw text and rendered markdown (per-conversation toolbar button)
- [x] Code blocks with copy button
- [x] Rendered inline in the bubble
- [x] Syntax highlighting in code blocks (regex-based, zero dependencies — keywords, strings, comments, numbers, types, decorators)

**Conversation import/export:**
- [x] Export conversation as JSON
- [x] Export conversation as Markdown file
- [x] Export conversation as PDF (not in original ROADMAP — bonus)
- [x] Import conversation from JSON
- [x] Bulk export: export all conversations as ZIP archive
- [x] File menu: Export (Cmd+E), Import (Cmd+Shift+I)

**Test criteria:**
- [x] Right-click audio attachment → Save As → saves to chosen location
- [x] Markdown renders correctly (bold, code blocks, lists)
- [x] Export → Import round-trip preserves all messages
- [x] Bulk export creates valid ZIP with all conversations

---

## Post-M13 Improvements (same session)

**Syntax highlighting** (`SyntaxHighlighter.swift`):
- Regex-based, zero dependencies. Covers keywords (Swift, Python, JS/TS, C/C++, Rust, Go, Java, Ruby, shell), types, strings, numbers, comments, decorators.
- Cached by `(code.hashValue, fontSize, isDark)` with 64-entry LRU. Dark mode aware.

**`@Query` migration:**
- Replaced ~20 manual `refreshConversations()` calls with `@Query(sort: \Conversation.updatedAt, order: .reverse)` in ContentView.
- Removed `refreshConversations()`, `scheduleCoalescedRefresh()`, `pendingRefreshWorkItem`.
- SwiftData auto-detects changes after `saveContext()`.

**Swift strict concurrency:**
- Enabled `SWIFT_STRICT_CONCURRENCY = complete` in both Debug and Release.
- Fixed ~40 warnings: `nonisolated(unsafe)` for static caches, `@MainActor` on Coordinator/ConversationExporter, `MainActor.assumeIsolated` for Timer callbacks, `UncheckedSendableBox` for SwiftData objects crossing isolation boundaries.
- Zero concurrency warnings remaining.

**Drag attachment to Finder:**
- `.onDrag` on AttachmentView with `NSItemProvider` providing the file URL and original filename.

**Rejected:** Visibility-based audio playback pause — bad UX for podcasts. Mini-player design handles scroll-out correctly.
