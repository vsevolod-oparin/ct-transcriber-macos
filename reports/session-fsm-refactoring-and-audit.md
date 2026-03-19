# Session Report: FSM Refactoring, Anti-Pattern Audit, and Crash Fixes

**Date:** 2026-03-19
**Commits:** `c07f2d6` (FSM refactoring) → `d8da7c0` (audit fixes) → `c8595b9` (minor fixes) → `aa15ad2` (crash fix)
**Scope:** 14 files changed, +2881 / -1889 lines

---

## What Was Done

### 1. Research: FSM for UI Programming

**Report:** `reports/research-fsm-ui-programming.md`

Researched the school of thought advocating finite state machines for UI development. Traced the lineage from Harel (1987 statecharts) through Horrocks (1999 book) to modern practitioners (XState/Khourshid, TCA/Point-Free). Identified 5 concrete improvement opportunities in the codebase.

### 2. FSM Refactoring (implemented)

**Added `MessageLifecycle` enum** (`Message.swift`) — 7 states: `complete`, `streaming`, `transcriptionQueued`, `transcribing`, `errorLLM`, `errorTranscription`, `cancelled`. Replaces fragile string-prefix state detection (`hasPrefix("⚠")`, `hasPrefix("⏳")`) with typed state.

**Added `ConversationActivity` enum** (`ChatViewModel.swift`) — replaces 3 separate tracking mechanisms (`streamingConversationIDs`, `streamingTasks`, `isGeneratingTitle`) with one `activities: [UUID: ConversationActivity]` dictionary. Per-conversation state instead of global booleans.

**Added `transcribingConversationIDs`** — per-conversation transcription tracking. Progress bar now shows only on the conversation being transcribed, not globally.

**Updated all state transitions** — every code path that creates, modifies, completes, errors, or cancels a message now sets the `lifecycle` property. Retry logic uses `lifecycle` instead of string matching.

### 3. Anti-Pattern Audit (implemented)

**Report:** `reports/research-antipattern-audit.md`

**CLAUDE.md updated** — rewrote "Anti-Patterns to Avoid" section from Obj-C++/Metal (wrong project) to Swift/SwiftUI/SwiftData with 6 categories, 20+ patterns. Added "Investigation discipline" section for crash/bug analysis.

**20 findings, 14 fixed:**

| Severity | Found | Fixed | Key items |
|----------|-------|-------|-----------|
| HIGH | 4 | 4 | `Task.detached` actor violations (2), `videoAspectRatioCache` data race, `pendingTranscriptions` holding model refs |
| MEDIUM | 8 | 5 | `@MainActor` on AudioPlaybackManager/ModelManager, `isDeleted` guards, file size split |
| LOW | 8 | 4 | `seekRequest` duplicate detection, SRT error handling, audio load failure UI, dead code |

### 4. ChatView.swift Split (implemented)

Split 2055-line file into 6 files:

| File | Contents | Lines |
|------|----------|-------|
| `ChatView.swift` | Main view, TranscriptionProgressBar, ErrorBanner, AutoTitleButton, TitleRenameField | ~270 |
| `ChatTableView.swift` | NSViewRepresentable, Coordinator, ChatNSTableView | ~530 |
| `MessageBubble.swift` | MessageBubble, MessageAnalysis, LargeTextView | ~450 |
| `MediaPlayerViews.swift` | AudioPlayerView, VideoPlayerView, MiniPlayerBar, etc. | ~600 |
| `AttachmentView.swift` | AttachmentView, ImageAttachmentView, FileAttachmentBadge | ~60 |
| `ChatInputBar.swift` | ChatInputBar, attachable content types | ~120 |

### 5. Crash Fixes (3 crashes investigated and fixed)

**Crash 1:** `Attachment.convertedName.getter` in `messageHash()` during `updateNSView`. Caused by SwiftData schema migration (new `lifecycle` property). Fixed by making `lifecycle` optional (`MessageLifecycle?`) and adding `isDeleted`/`modelContext` guards.

**Crash 2:** Same crash site but triggered by **NSAlert dismissal** (delete confirmation). Hit testing during sheet close forces SwiftUI view graph update, accessing cascade-deleted attachment properties. `isDeleted` guards insufficient — SwiftData synthesized getters crash even when guards pass. Fixed by removing all attachment relationship traversal from `messageHash()`.

**Crash 3:** `Attachment.id.getter` in `ForEach(message.attachments)`. Same alert-dismissal trigger, different code path — SwiftUI `ForEach` needs element IDs, accesses `.id` on faulted attachments. Fixed by filtering `message.attachments` with `!isDeleted && modelContext != nil` before `ForEach`.

**Root cause pattern:** NSAlert dismissal → window reordering → hit testing → SwiftUI view graph update → accesses SwiftData relationship targets (Attachments) that were cascade-deleted in the same run loop. No Swift-level guard reliably prevents this — the fix is to avoid relationship traversal in hot paths.

### 6. Performance Fixes

- Transcription stream loop moved from MainActor (`Task`) to `Task.detached` — zero MainActor hops between 300ms throttle intervals
- `AVAsset.tracks(withMediaType:)` moved off MainActor
- `deleteConversation` restructured — collects file paths before deletion, file I/O moved to `Task.detached`
- Coalesced refresh for attachment flow (N attachments → 1 `refreshConversations()`)
- `finishTranscription` yields run loop before starting next transcription
- `sortedMessages` filters deleted messages to prevent faulting

---

## Known Bugs (documented but not fully resolved)

### Bug (b): Brief typing freeze at transcription transitions

When one transcription finishes and another starts, there's a brief input freeze. Root cause: `saveContext()` + `refreshConversations()` on MainActor triggers full SwiftUI view tree re-evaluation. Mitigated (throttling, run loop yield) but not eliminated. Full fix requires replacing `refreshConversations()` with targeted SwiftData observation or `@Query`.

### Bug (c): Brief input block when attaching multiple audio files

First file appears immediately, then brief freeze before remaining files appear. Root cause: per-file `saveContext()` + `startTranscription()` setup on MainActor. Mitigated (coalesced refresh, skip redundant saves). Full fix requires batching all N attachment creations into a single MainActor block.

---

## What the ROADMAP Says About Next Steps

All milestones through **M11b (Audit Fixes)** are complete. The project is at **v0.2.0** — a working, distributed macOS app.

### Planned future milestones:

**Milestone 12: MCP Support** (Future)
- Research MCP Swift SDK
- Implement MCP client for tool use in chat
- Tool-use UI (expandable cards)

**Milestone 13: Content Export & Markdown** (Future)
- Save As for attachments, SRT/TXT/MD export
- Markdown rendering in assistant messages (bold, code blocks, lists, syntax highlighting)
- Conversation import/export (JSON, Markdown, bulk ZIP)

### Future considerations (from TelegramSwift research):
- Priority queue for transcriptions
- Lite Mode / Low Power settings
- Extract services into local Swift Package (when >50 files)

### What this session suggests should come next:

1. **Fix bugs (b) and (c) properly** — replace `refreshConversations()` with `@Query` or targeted observation. This is architectural but would eliminate the MainActor saturation pattern at its root.
2. **Milestone 13 (Markdown)** — markdown rendering in assistant messages would significantly improve the chat experience, especially for LLM responses that use formatting.
3. **Wire up `SchemaVersioning.swift`** — it's dead code. Before the next schema change, it should either be properly integrated or removed.
4. **Swift 6 concurrency readiness** — the `@MainActor` additions and `Task.detached` fixes prepare for strict concurrency, but full Swift 6 compliance would catch remaining issues at compile time.
