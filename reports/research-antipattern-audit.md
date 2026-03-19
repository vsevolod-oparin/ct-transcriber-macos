# Anti-Pattern Audit: CTTranscriber Codebase

**Date:** 2026-03-19
**Scope:** Full codebase audit against Swift/SwiftUI/SwiftData anti-patterns, following FSM refactoring

---

## Summary

| Severity | Count | Categories |
|----------|-------|------------|
| HIGH     | 4     | Concurrency (3), SwiftData (1) |
| MEDIUM   | 8     | Concurrency (3), SwiftData (2), SwiftUI State (1), NSViewRepresentable (1), File Size (1) |
| LOW      | 8     | SwiftUI State (1), Performance (2), Error Handling (2), Code Quality (2), Dead Code (1) |

---

## HIGH Severity

### 1. `Task.detached` in `autoNameConversation` accesses `@MainActor` self off-actor

**File:** `ChatViewModel.swift:512-550`

`Task.detached { [weak self] in ... }` resolves `weak self` off MainActor for a `@MainActor`-isolated class. The `conversation` SwiftData object is captured implicitly across actor boundary. Swift 6 strict concurrency will reject this.

**Fix:** Replace `Task.detached` with regular `Task` (inherits MainActor), or move only the network call into a detached context and handle all self/model access in `MainActor.run`.

### 2. `Task.detached` in `attachFile` passes SwiftData object across actor boundary

**File:** `ChatViewModel.swift:584-601`

`conversation` (SwiftData `@Model`) captured into `Task.detached`. SwiftData models are not `Sendable`. The mutation happens inside `MainActor.run` but the reference crosses the boundary.

**Fix:** Pass `conversation.id` into the detached task, re-fetch the conversation inside `MainActor.run`.

### 3. `videoAspectRatioCache` — static dictionary data race

**File:** `ChatView.swift:555-577`

`static var videoAspectRatioCache: [String: CGFloat]` is written from `Task.detached(priority: .utility)` (ChatViewModel.swift:609) and read from main thread. No synchronization.

**Fix:** Make it actor-protected, use a serial DispatchQueue, or ensure all writes dispatch to MainActor.

### 4. `pendingTranscriptions` holds strong SwiftData object references

**File:** `ChatViewModel.swift:93`

`pendingTranscriptions` stores `(conversation: Conversation, message: Message)` tuples. If conversation is deleted while items are queued, dequeuing accesses faulted objects.

**Fix:** Store `conversationID: UUID` and `messageID: UUID`, re-fetch from ModelContext when dequeuing.

---

## MEDIUM Severity

### 5. `AudioPlaybackManager` missing `@MainActor`

**File:** `AudioPlaybackManager.swift:7`

`@Observable` singleton without `@MainActor`. Timer callbacks and view accesses assume main thread but compiler can't enforce it.

**Fix:** Add `@MainActor` annotation.

### 6. `ModelManager` missing `@MainActor`

**File:** `ModelManager.swift:5`

Same issue as #5. `downloadModel` spawns a Task that accesses `self` and `settingsManager` without actor isolation.

**Fix:** Add `@MainActor` annotation.

### 7. Timer closure in `AudioPlayerView` accesses `@State` from non-view context

**File:** `ChatView.swift:1459-1469`

`Timer.scheduledTimer` callback reads/writes `@State` properties (`currentTime`, `isPlaying`). While this runs on main thread in practice, `@State` isn't designed for arbitrary closure access.

**Fix:** Replace with `.onReceive(Timer.publish(...))` or `TimelineView`.

### 8. No `isDeleted` check in `retryMessage`

**File:** `ChatViewModel.swift:236-293`

Accesses `message.role`, `message.content`, `message.lifecycle` and traverses `conversation.messages` without guarding against deleted objects.

**Fix:** Add `guard !message.isDeleted, !conversation.isDeleted else { return }`.

### 9. `persistPosition()` doesn't save context

**File:** `ChatView.swift:1490-1495`, `ChatView.swift:1707-1708`

Sets `attachment.playbackPosition` without explicit `saveContext()`. Position may be lost on crash.

**Status:** Acceptable — documented as intentional trade-off (low-stakes data).

### 10. Trigger counter fragility

**File:** `ChatViewModel.swift:47-51`

`focusCounter`, `scrollToTopTrigger`, `scrollToBottomTrigger` can lose events if incremented twice per run loop.

**Status:** Known limitation, documented in CLAUDE.md anti-patterns.

### 11. `toggleExpanded` missing `isDeleted` guard

**File:** `ChatView.swift:600`

Accesses `messages[row]` without checking `isDeleted`. Other delegate methods were guarded but this was missed.

**Fix:** Add `guard row < messages.count, !messages[row].isDeleted else { return }`.

### 12. `ChatView.swift` is ~2000 lines

**File:** `ChatView.swift`

Contains table view, coordinator, message bubble, audio player, video player, image view, file badge, mini player, title rename field, and input bar. Clear SRP violation.

**Fix:** Extract into separate files in a future refactor.

---

## LOW Severity

### 13. `seekRequest` tuple — duplicate time values not detected

**File:** `ChatView.swift:1376`

`onChange(of: seekRequest?.time)` ignores seeks to same time with different `storedName`.

### 14. `sortedMessages(for:)` sorts on every call

**File:** `ChatViewModel.swift:115-117`

Called from ChatView.body (every render), retryMessage, buildMessageDTOs, stopStreaming. During streaming, this sorts repeatedly.

### 15. `filteredConversations` scans all message content

**File:** `ChatViewModel.swift:28-35`

Full-text search computed property runs on every render. O(n*m) where n=conversations, m=messages.

### 16. `MessageAnalysis` duplicated initializers

**File:** `ChatView.swift:746-852`

`init(message:)` and `init(content:)` share ~90% identical code. Will diverge over time.

### 17. SRT export silently swallows write error

**File:** `ChatView.swift:1153`

`try? srt.write(...)` — user gets no feedback on failure.

### 18. Audio load failure not surfaced to UI

**File:** `ChatView.swift:1400-1402`

`AVAudioPlayer(contentsOf:)` failure logged but play button remains visible and non-functional.

### 19. Dead code in `toggleExpanded`

**File:** `ChatView.swift:614-634`

`updatedBubble` constructed but never assigned to cell. The actual update uses `reloadData(forRowIndexes:)`.

### 20. `ChatViewModel.swift` at 834 lines

**File:** `ChatViewModel.swift`

Slightly over the 800-line target. Transcription and file attachment logic could be extracted.

---

## Actions Taken

### Phase 1 (FSM refactoring session)

1. `isDeleted` guards added to `messageHash()`, `updateNSView()`, `viewFor`, `heightOfRow` (crash fix)
2. `deleteConversation` now cancels streaming/titling tasks from `activities` dictionary
3. `stopStreaming` now sets assistant message lifecycle to `.complete`
4. CLAUDE.md anti-patterns section rewritten for Swift/SwiftUI/SwiftData

### Phase 2 (anti-pattern fixes)

5. **HIGH #1:** `autoNameConversation` — replaced `Task.detached` with `Task` (inherits MainActor), removed `MainActor.run` wrappers
6. **HIGH #2:** `attachFile` — now captures `conversation.id`, re-fetches inside `MainActor.run`
7. **HIGH #3:** `videoAspectRatioCache` — writes now dispatch to `DispatchQueue.main.async`
8. **HIGH #4:** `pendingTranscriptions` — stores `(conversationID: UUID, messageID: UUID)` instead of model objects; `finishTranscription` re-fetches with `while` loop to skip deleted items
9. **MEDIUM #5:** `AudioPlaybackManager` — added `@MainActor`
10. **MEDIUM #6:** `ModelManager` — added `@MainActor`, `nonisolated deinit`, `nonisolated static func directorySize`
11. **MEDIUM #8:** `retryMessage` — added `isDeleted` guard
12. **MEDIUM #11:** `toggleExpanded` — added `isDeleted` guard
13. **LOW #16:** `MessageAnalysis` — extracted shared logic into `analyze(content:isError:)` helper
14. **LOW #19:** `toggleExpanded` — removed dead `updatedBubble` code block

Build: **SUCCEEDED** | Unit tests: **ALL PASSED**

### Phase 3 (crash investigation + performance)

15. **Crash: `Attachment.convertedName.getter` in `messageHash`** — caused by NSAlert dismissal triggering hit-test → SwiftUI view graph update while conversation cascade-deleted. `isDeleted`/`modelContext` guards insufficient — SwiftData synthesized getters crash even when guards pass for cascade-deleted relationship targets. **Fix:** removed all attachment property access from `messageHash()` — hash uses only `msg.content.count`.
16. **Crash: `Attachment.id.getter` in `ForEach`** — same alert-dismissal trigger, different path: SwiftUI `ForEach(message.attachments)` accesses `.id` on faulted attachments. **Fix:** filter with `!isDeleted && modelContext != nil` before ForEach.
17. **`sortedMessages(for:)`** — added `isDeleted`/`modelContext` guard for conversation + filters deleted messages. Prevents relationship traversal on deleted objects.
18. **`deleteConversation`** — restructured: collects file paths as value types before deletion, moves file I/O to `Task.detached`, eliminates post-delete relationship traversal.
19. **BackgroundTask cleanup** — `cancelTranscriptionTasks` now also calls `taskManager.cancelTask()` on running transcription BackgroundTask objects.
20. **Transcription stream off MainActor** — changed from `Task` (inherited MainActor) to `Task.detached` with throttled `MainActor.run` hops (300ms interval). Eliminates MainActor saturation during transcription.
21. **Audio track check off MainActor** — `AVAsset.tracks(withMediaType:)` moved into the detached task.
22. **Coalesced refresh** — `scheduleCoalescedRefresh()` debounces `refreshConversations()` for attachment flow. N rapid attachments → 1 refresh.
23. **`finishTranscription` yields run loop** — `DispatchQueue.main.async` before starting next transcription.
24. **`transcribeAudio` skips redundant save** — `skipSaveRefresh` flag when called from `attachFile`.

## Known Bugs (not fully resolved)

### Bug (b): Typing throttle during transcription transitions

**Symptom:** When one transcription finishes and another starts, there is a brief period where user input freezes. Typing appears to stop, then all characters appear at once.

**Root cause:** The transition between transcriptions involves `finishTranscription` → `saveContext()` + `refreshConversations()` → `startTranscription()` (via `DispatchQueue.main.async`). Each step runs on MainActor. `refreshConversations()` re-fetches all conversations from SwiftData and triggers `@Observable` notifications, which causes full SwiftUI view tree re-evaluation. The `DispatchQueue.main.async` yield helps but doesn't eliminate the freeze if the refresh + view update takes longer than a frame.

**Mitigations applied:**
- Transcription stream loop runs off MainActor (`Task.detached`)
- UI updates throttled to 300ms intervals (zero MainActor hops between intervals)
- `finishTranscription` yields run loop before starting next transcription
- `skipSaveRefresh` eliminates redundant saves during attachment flow

**What would fully fix it:** Replace `refreshConversations()` (full re-fetch) with targeted SwiftData observation — only update the specific conversation that changed, not the entire list. Or use `@Query` which handles incremental updates. This is a significant architectural change.

### Bug (c): Brief input block when attaching multiple audio files

**Symptom:** When attaching multiple audio files at once, the first appears immediately, then there is a short gap where typing is blocked before the remaining files appear.

**Root cause:** Each `attachFile` completion runs a `MainActor.run` block that creates a Message + Attachment, calls `saveContext()`, and triggers `postAttachActions` (which calls `transcribeAudio` → `startTranscription`). With N files, N completion blocks queue on MainActor. Each block does SQLite writes and triggers SwiftUI observation. The coalesced refresh helps (1 refresh instead of N), but the per-file `saveContext()` + `startTranscription()` setup work still runs synchronously.

**Mitigations applied:**
- File I/O (`FileStorage.copyToStorage`) runs in `Task.detached`
- Audio track check (`AVAsset.tracks`) moved off MainActor into detached task
- Coalesced refresh: N attachments → 1 `refreshConversations()` call
- `skipSaveRefresh` in `transcribeAudio` when called from attachment flow

**What would fully fix it:** Batch all N attachment creations into a single `saveContext()` call. This requires restructuring `attachFile` to collect results from all detached copy tasks before doing a single MainActor block for all N messages. Or: use a serial background queue for attachment processing and only notify MainActor once at the end.

## Remaining (not fixed — future work)

- **MEDIUM #7:** Timer closure in `AudioPlayerView` — replace with `.onReceive(Timer.publish(...))` (functional, low risk)
- **MEDIUM #9:** `persistPosition()` missing save — documented as acceptable trade-off
- **MEDIUM #10:** Trigger counter fragility — documented in CLAUDE.md
