# Milestone 8b: Performance & Architecture (Immediate Fixes)

**Date:** 2026-03-17
**Status:** Immediate fixes complete. NSTableView migration and remaining items deferred.

---

## What Was Done

### Research Phase

Analyzed TelegramSwift (1,265 Swift files) against CT Transcriber (27 files). Full analysis in `reports/research-telegramswift-best-practices.md`. Key finding: Telegram's pure AppKit + custom FRP stack is overengineered for our scale, but specific patterns around scroll throttling, background processing, and cache invalidation are directly adoptable.

### Scroll Throttle During Streaming

**Problem:** `onChange(of: lastContentLength)` fired on every character during LLM streaming, causing ScrollView to re-layout per token.

**Fix:** Added `streamingScrollCharThrottle = 50` — scroll only triggers every 50 characters. Also added `onChange(of: isStreaming)` to ensure a final scroll when streaming ends.

**Files:** `ChatView.swift` (MessageListView)

### MessageAnalysis Recomputation Throttle

**Problem:** `.task(id: message.content.count)` recomputed `MessageAnalysis` on every token during streaming — CPU overhead for line counting, error detection, preview generation.

**Fix:** Added `analysisRecomputeThrottle = 500` — during streaming, analysis only recomputes every 500 characters. Non-streaming messages recompute immediately.

**Files:** `ChatView.swift` (MessageBubble)

### PythonEnvironment Off Main Thread

**Problem:** `PythonEnvironment.check()` calls `runPython()` which uses `Process().waitUntilExit()` — blocks main thread on startup.

**Fix:** Wrapped in `Task.detached(priority: .userInitiated)` in ContentView, result applied on `MainActor`.

**Files:** `ContentView.swift`

### ModelManager.directorySize() Off Main Thread

**Problem:** `directorySize()` enumerates all files in a model directory synchronously — could block for seconds on large models (3+ GB).

**Fix:** Made `directorySize` static, called via `Task.detached(priority: .utility)`. Status immediately shows `.ready(path, sizeMB: 0)`, then updates asynchronously when size computation finishes.

**Files:** `ModelManager.swift`

### Transcription Task Cleanup on Conversation Delete

**Problem:** `transcriptionTasks[UUID: Task]` dictionary and `pendingTranscriptions` array were not cleaned up when a conversation was deleted — leaked Swift Tasks and queued work.

**Fix:** `deleteConversation()` now:
1. Cancels all active transcription tasks for the conversation's messages
2. Removes pending transcriptions for the deleted conversation
3. Resets `activeTranscriptionCount` and `transcriptionProgress`

**Files:** `ChatViewModel.swift`

### Deinit Logging

Added `deinit { AppLogger.debug("...deinit", category: "lifecycle") }` to:
- `ChatViewModel`
- `TaskManager`
- `ModelManager`

Logs appear in `ct-transcriber.log` under the `lifecycle` category — useful for spotting retain cycles during development.

### TaskManagerProtocol

Extracted protocol:
```swift
protocol TaskManagerProtocol: AnyObject {
    var tasks: [BackgroundTask] { get }
    var activeCount: Int { get }
    func createTask(kind: TaskKind, title: String, context: String?) -> BackgroundTask
    func deleteTask(_ task: BackgroundTask)
    func cancelTask(_ task: BackgroundTask)
    func clearCompleted()
}
```

`TaskManager` now conforms to `TaskManagerProtocol`. Enables mock injection for unit tests.

**Files:** `TaskManager.swift`

### Constructor-Based DI for ChatViewModel

**Before:** `settingsManager`, `modelManager`, `taskManager` were optional vars assigned post-init.

**After:** `settingsManager` and `modelManager` are non-optional `let` properties injected via `init(modelContext:settingsManager:modelManager:)`. `taskManager` remains `var` because it's created after the ViewModel in ContentView's `.task {}`.

This eliminated ~10 optional unwraps (`settingsManager?`, `modelManager?`) and the `defaultMaxParallelTranscriptions` fallback constant.

**Files:** `ChatViewModel.swift`, `ContentView.swift`

### Log Rotation

**Problem:** `ct-transcriber.log` grew unbounded.

**Fix:** Before each write, checks if file exceeds 10 MB. If so, rotates:
- `ct-transcriber.log` → `ct-transcriber.log.1`
- `.1` → `.2`, `.2` → `.3`
- `.3` (oldest) deleted

Keeps up to 3 rotated files (30 MB total max).

**Files:** `AppLogger.swift`

---

## Files Modified

- **`ChatView.swift`** — Scroll throttle (50 chars), MessageAnalysis recomputation throttle (500 chars), streaming end scroll
- **`ChatViewModel.swift`** — Constructor DI, transcription cleanup on delete, deinit logging, removed optional unwraps
- **`ContentView.swift`** — Async environment check, updated ViewModel construction
- **`ModelManager.swift`** — Background directorySize, deinit logging, static method
- **`TaskManager.swift`** — TaskManagerProtocol, deinit logging
- **`AppLogger.swift`** — Log rotation (10MB, 3 files)

---

## Deferred Items

| Item | Reason |
|------|--------|
| `isDynamicContentLocked` for LargeTextView | Requires NSTableView migration for proper implementation |
| Cache `collapsedPreview` on message model | Minor optimization, can be done with NSTableView row height cache |
| NSCache for thumbnails | No image/video preview UI yet |
| Visibility-based audio playback pause | Audio player is basic (play/pause only) |
| NSTableView migration | Large effort — separate milestone phase |
| Priority queue for transcriptions | Future |
| Lite Mode | Future |
| Swift Package extraction | Future (at ~50 files) |
