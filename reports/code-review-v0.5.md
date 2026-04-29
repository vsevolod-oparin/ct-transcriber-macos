# Code Review — CT Transcriber v0.5.1

**Date:** 2026-04-27  
**Scope:** All 38 Swift source files (~8,500 lines)  
**Categories:** Stability, crashes, bugs, performance, code style

---

## Fix Priority Order

| Priority | # | Issue | Severity | File |
|----------|---|-------|----------|------|
| 1 | 1 | Deleting conversation cancels ALL transcriptions | CRITICAL | ChatViewModel.swift |
| 2 | 2 | Data race in SyntaxHighlighter cache | CRITICAL | SyntaxHighlighter.swift |
| 3 | 3 | Message bubble context menu is dead code | HIGH | MessageBubble.swift |
| 4 | 4 | Video aspect-ratio cache uses 16:9 as sentinel | HIGH | ChatTableView.swift |
| 5 | 5 | UncheckedSendableBox wraps @Model across actors | HIGH | ChatViewModel.swift |
| 6 | 6 | AudioPlayerView Timer fires 10×/sec even when paused/off-screen | MEDIUM | MediaPlayerViews.swift |
| 7 | 7 | measureRowHeight creates NSHostingController per call | MEDIUM | ChatTableView.swift |
| 8 | 8 | seekPlayer recreates AVAudioPlayer from disk on every seek | MEDIUM | MediaPlayerViews.swift |
| 9 | 9 | filteredConversations is O(N×M) on every body eval | MEDIUM | ChatViewModel.swift |
| 10 | 11 | findAudioAttachment sorts all messages per render | MEDIUM | MessageBubble.swift |
| 11 | 12 | Closure captures in AudioPlaybackManager may leak | MEDIUM | MediaPlayerViews.swift |
| 12 | 10 | Process.waitUntilExit() blocks cooperative pool | MEDIUM | VideoConverter.swift |
| 13 | 13 | lastPositions dictionary grows unbounded | MEDIUM | AudioPlaybackManager.swift |
| 14 | 14 | Force-unwraps on FileManager.urls(for:) | LOW | FileStorage/SettingsStorage/ModelManager |
| 15 | 15 | Force-unwrap on SRT content type | LOW | MessageBubble.swift |
| 16 | 16 | SettingsStorage uses print() not AppLogger | LOW | SettingsStorage.swift |
| 17 | 17 | conversationDidChange uses UUID() as nil key | LOW | ChatViewModel.swift |
| 18 | 18 | TranscriptTextView uses char-count for change detection | LOW | MessageBubble.swift |
| 19 | 19 | saveAttachment copyItem fails if dest exists | LOW | AttachmentView.swift |
| 20 | 20 | Export/import doesn't preserve attachment files | LOW | ConversationExporter.swift |

---

## Issue Details

### #1 — Deleting conversation cancels ALL transcriptions [CRITICAL]

`ChatViewModel.cancelTranscriptionTasks(for:)` (line 253) cancels every running transcription task and clears all tracking state (`activeTranscriptionCount = 0`, `transcribingConversationIDs.removeAll()`), regardless of which conversation owns them. Deleting conversation A silently kills transcriptions in B, C, etc.

**Fix:** Track `conversationID` alongside each task. Key `transcriptionTasks` by a composite or add a parallel dictionary. Only cancel tasks belonging to the deleted conversation.

### #2 — Data race in SyntaxHighlighter cache [CRITICAL]

`SyntaxHighlighter.swift` line 140: `nonisolated(unsafe) private static var cache` is a plain Swift Dictionary accessed from SwiftUI body evaluations. Concurrent reads/writes cause undefined behavior — potential EXC_BAD_ACCESS.

**Fix:** Replace with `NSCache` (thread-safe) or add `os_unfair_lock` / `NSLock` protection.

### #3 — Message bubble context menu is dead code [HIGH]

`MessageBubble.bubbleContextMenu(info:)` (line 330) builds a full right-click menu (copy, copy without timestamps, play from timestamp, export SRT/text/markdown, retry) but it is never attached to any view. Users have no context menu on messages.

**Fix:** Add `.contextMenu { bubbleContextMenu(info: info) }` to the bubble view in `bodyContent`.

### #4 — Video aspect-ratio cache: 16:9 fallback = "not cached" [HIGH]

`ChatTableView.Coordinator.videoAspectRatio(url:)` returns 16:9 for "not yet computed." This means:
- Real 16:9 videos trigger redundant async recomputation in `VideoPlayerView`
- `precomputeVideoRatios` guard skips already-cached 16:9 correctly but the semantics are fragile

**Fix:** Return `nil` for "not cached." Update callers to use `?? (16.0/9.0)`.

### #5 — UncheckedSendableBox wraps @Model across actor boundaries [HIGH]

`ChatViewModel.startTranscription` (line 775) wraps SwiftData `@Model` objects (`Message`, `BackgroundTask`) in `@unchecked Sendable` boxes captured by `Task.detached`. While mutations happen inside `MainActor.run` blocks, SwiftData models aren't documented as safe to reference from non-isolated contexts. A lazy relationship fault triggered on the wrong context could crash.

**Fix:** Pass only primitive IDs into the detached task. Re-fetch model objects inside `MainActor.run`.

### #6 — AudioPlayerView Timer fires continuously [MEDIUM]

`MediaPlayerViews.swift` line 97: `Timer.publish(every: 0.1).autoconnect()` fires 10×/sec per audio player view. With multiple attachments (visible + off-screen), this wastes main-thread cycles.

**Fix:** Only create/connect the timer when `isPlaying == true`. Invalidate on pause/stop.

### #7 — measureRowHeight creates NSHostingController per call [MEDIUM]

`ChatTableView.Coordinator.measureRowHeight` (line 462) creates and discards an `NSHostingController` for every uncached row height measurement. This is expensive (full NSView hierarchy allocation).

**Fix:** Reuse a single `NSHostingController` instance. Reset its root view between measurements.

### #8 — seekPlayer recreates AVAudioPlayer from disk on every seek [MEDIUM]

`MediaPlayerViews.swift` line 226: Every seek destroys the current player, reads the file from disk, creates a new `AVAudioPlayer`. This blocks the main thread with I/O.

**Fix:** Set `player.currentTime` directly. Only recreate if the player was stopped (not paused).

### #9 — filteredConversations is O(N×M) computed property [MEDIUM]

`ChatViewModel.filteredConversations` (line 35) searches every message in every conversation. Called on every SwiftUI body evaluation — potentially multiple times per frame.

**Fix:** Cache the result; invalidate on `searchText` or `conversations` change.

### #10 — Process.waitUntilExit() blocks cooperative thread pool [MEDIUM]

`VideoConverter.convertToMP4` (line 58) and `ConversationExporter.exportBulkZIP` (line 329) call `waitUntilExit()` synchronously inside async contexts, blocking cooperative pool threads.

**Fix:** Wrap in `Task.detached` or use the async `process.run()` + notification pattern.

### #11 — findAudioAttachment sorts all messages per render [MEDIUM]

`MessageBubble.findAudioAttachment()` (line 555) sorts all messages in the conversation. Called from `bubbleContent`, `exportAsSRT`, `deriveExportFilename`. For height measurement + rendering, this is called many times per cell.

**Fix:** Cache the audio attachment name on the message or pass it as a parameter during construction.

### #12 — Closure captures in AudioPlaybackManager callbacks [MEDIUM]

Callbacks stored in `AudioPlaybackManager.shared` (`pauseCallback`, `resumeCallback`, etc.) capture `self` (the SwiftUI view), which transitively holds `AVPlayer`/`AVAudioPlayer`. Singleton holds these until `stopAll()`.

**Fix:** Use `[weak self]` in all closures. Ensure cleanup is comprehensive.

### #13 — lastPositions dictionary grows unbounded [MEDIUM]

`AudioPlaybackManager.lastPositions` accumulates entries for every file ever played. Never pruned.

**Fix:** Cap at 100 entries or clear stale entries on launch.

### #14-20 — Low severity issues

See inline file references in the priority table above. These are code-quality improvements (force-unwraps, print vs logger, minor correctness).

---

## Style Notes

- **Duplicate NSViewRepresentable Coordinator logic:** `TitleRenameField` and `SelectAllTextField` share 90% identical code. Extract a shared base.
- **ChatViewModel at 1023 lines:** Consider extracting `TranscriptionCoordinator`, `LLMStreamingManager`.
- **Global constants** (`collapseThreshold`, etc.) should be scoped/private.
- **ScaledFont** should conform to `Sendable`.
