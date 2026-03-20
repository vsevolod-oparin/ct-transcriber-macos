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

## Known Bugs — RESOLVED (v0.3.1)

### Bug (b): Typing freeze at transcription transitions — FIXED

Root cause found via timing instrumentation: `PythonEnvironment.check()` spawned a Python subprocess (1100-1800ms) on every `startTranscription` call. Fixed by caching the check result. All other MainActor operations measured at 1-52ms.

### Bug (c): Input block with multiple audio attachments — FIXED

Same root cause as bug (b). With PythonEnvironment caching, the per-file overhead is eliminated.

---

## What the ROADMAP Says About Next Steps

All milestones through **M13 (Content Export & Markdown)** are complete. The project is at **v0.4.0**.

### Planned future milestones:

**Milestone 12: MCP Support** (Future)
- Research MCP Swift SDK
- Implement MCP client for tool use in chat
- Tool-use UI (expandable cards)

**Milestone 13: Content Export & Markdown** — ✅ Complete (v0.4.0)

### Subsequent session resolved:
1. **Bugs (b) and (c)** — ✅ Fixed in v0.3.1. Root cause: `PythonEnvironment.check()` spawning a subprocess (1.1s) on every transcription start. Fixed by caching.
2. **Milestone 13** — ✅ Complete in v0.4.0. Markdown rendering, PDF/JSON/MD export, import, media save.
3. **SchemaVersioning.swift** — ✅ Wired up in v0.3.0 with 8 unit tests.

### Remaining future work:
- **M12: MCP Support** — tool use in LLM chat
- **Swift 6 concurrency readiness** — full strict concurrency compliance
- Code syntax highlighting (needs third-party dependency)
- Priority queue for transcriptions, Lite Mode, Swift Package extraction
