# Milestone 2: Persistent Storage (SwiftData)

**Date:** 2026-03-16
**Status:** Complete

---

## What Was Done

### SwiftData Integration

Replaced the in-memory mock-data `ChatViewModel` with a SwiftData-backed implementation.

**Models:**
- `Conversation` — `@Model` with `id`, `title`, `createdAt`, `updatedAt`, cascade-delete relationship to messages
- `Message` — `@Model` with `id`, `role` (enum), `content`, `timestamp`, cascade-delete relationship to attachments, conversation relationship
- `Attachment` — `@Model` with `id`, `kind` (audio/video/image/text), `storedName` (UUID filename on disk), `originalName` (user-facing), message relationship

**ChatViewModel** — rewritten to use `ModelContext`:
- `conversations` computed property: fetches all conversations sorted by `updatedAt` descending
- `selectedConversation`: fetches by ID predicate
- `sortedMessages(for:)`: sorts conversation's messages by timestamp
- `createConversation()`: inserts into context + saves
- `deleteConversation()`: cleans up stored files for all attachments, deletes from context, auto-selects next
- `sendMessage()`: creates Message, appends to conversation, auto-titles if first message
- `renameConversation()`: updates title + updatedAt
- `attachFile(from:to:)`: copies file to app storage, auto-detects kind from UTType, creates message with Attachment

### File Storage

**`FileStorage`** (unified service, replaces earlier `AudioFileStorage`):
- Stores all files at `~/Library/Application Support/CTTranscriber/files/{uuid}.{ext}`
- `copyToStorage(from:)` → copies source file, returns stored filename
- `writeToStorage(data:extension:)` → writes raw data (for LLM/MCP-generated content)
- `url(for:)` → resolves stored name to full URL
- `delete(storedName:)` → removes file from disk
- `attachmentKind(for:)` → auto-detects kind from UTType (audio, video, image, text)
- Creates directory lazily on first write

### Supported Attachment Types

| Kind | UTTypes | Icon |
|------|---------|------|
| Audio | `.audio` | waveform |
| Video | `.movie`, `.video` | film |
| Image | `.image` | photo |
| Text | `.plainText`, `.sourceCode`, `.utf8PlainText`, `.text` | doc.text |

File picker allows multiple selection of all types above.

### Auto-Title

When the first message is sent to a "New Conversation", the title is auto-generated from the message text (truncated at `autoTitleMaxLength` = 50 chars with "..." suffix). Later (M4) this will be replaced with LLM-generated titles.

### View Wiring Changes

- `ContentView`: gets `ModelContext` from environment, creates `ChatViewModel` on appear
- `ChatView`: uses `viewModel.sortedMessages(for:)` instead of direct array access
- `ChatInputBar`: accepts multi-file selection for audio/video/image/text
- `AttachmentView`: shows kind-specific icon + original filename above message bubble
- `CTTranscriberApp`: model container registers `Conversation`, `Message`, and `Attachment`
- Mock data removed — app starts empty, data persists across restarts

---

## Key Decisions

- **Unified `Attachment` model** rather than per-type fields on Message: extensible for future types, clean cascade delete, each attachment tracks its own kind and filenames.
- **Computed `conversations` property** (re-fetches on access) vs `@Query` in views: chose view model fetch to keep all data logic in one place.
- **Files stored by UUID filename** rather than original name: avoids collisions, simpler cleanup. Original filename preserved in `Attachment.originalName`.
- **`writeToStorage(data:extension:)`** added proactively for LLM/MCP-generated content (images, videos) that arrive as raw data rather than file URLs.

---

## Test Criteria Results

| Criteria | Result |
|----------|--------|
| Create conversation, add messages, quit app, relaunch — data persists | PASS |
| Delete conversation — messages, attachments, and stored files cleaned up | PASS |
| Attach audio file — copied to app storage, reference in message | PASS |
| Attach image/video/text — correctly detected, stored, shown with icon | PASS |

---

## Files Created/Modified

- **Created:** `Models/Attachment.swift`, `Services/FileStorage.swift`
- **Modified:** `Models/Message.swift` (audioFilePath → attachments relationship), `ViewModels/ChatViewModel.swift` (SwiftData + attachFile), `Views/ContentView.swift` (ModelContext wiring), `Views/ChatView.swift` (AttachmentView, multi-type file picker), `App/CTTranscriberApp.swift` (model container)
- **Removed:** `Services/AudioFileStorage.swift`, mock data seeding
