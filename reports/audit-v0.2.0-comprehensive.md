# Comprehensive Audit Report — CT Transcriber v0.2.0

**Date:** 2026-03-19
**Scope:** 30 Swift files, ~6.5K lines, 2 Python scripts, 1 shell script
**Auditors:** 6 parallel agents (UI/UX, Async/Concurrency, Data/Logic, Performance, Architecture, TelegramSwift comparison)

---

## Executive Summary

The app is well-structured MVVM-S with clean layer separation, appropriate for its ~6.5K line scale. The NSTableView chat migration and streaming optimizations are production-quality. The main concerns are: **ChatViewModel accumulating too many responsibilities** (9+), **data races on shared mutable state**, **silent error suppression in persistence**, and **orphaned Python subprocesses on cancellation**.

| Severity | Count | Categories |
|----------|-------|------------|
| CRITICAL | 4 | Security (command injection), data races, orphaned files |
| HIGH | 10 | Threading, process management, error suppression, UI blocking |
| MEDIUM | 18 | Architecture, performance, missing validation, edge cases |
| LOW | 12 | Polish, accessibility, naming, organization |

---

## CRITICAL (Must Fix)

### C1. Command Injection in AppUninstaller
**File:** `AppUninstaller.swift:23-30`
**Issue:** Paths interpolated into shell script without escaping. Backticks or `$(...)` in path could execute arbitrary commands.
**Fix:** Use `Process` with argument array instead of shell string interpolation.

### C2. Data Race on streamingConversationIDs
**File:** `ChatViewModel.swift:46, 316, 374`
**Issue:** `Set<UUID>` modified from multiple Task contexts without synchronization. `@Observable` does not provide thread safety.
**Fix:** Ensure all mutations happen on `@MainActor`, or use actor isolation.

### C3. Data Race on transcriptionTasks Dictionary
**File:** `ChatViewModel.swift:72, 612, 689-692`
**Issue:** Dictionary modified from background Tasks and MainActor concurrently.
**Fix:** Same as C2 — consolidate all access on MainActor.

### C4. Orphaned Converted MP4 Files on Delete
**File:** `ChatViewModel.swift:170-173`
**Issue:** When conversations are deleted, `attachment.convertedName` (MP4 conversions) are never cleaned up. Only `storedName` is deleted.
**Fix:** Also delete `convertedName` files in the delete loop.

---

## HIGH (Should Fix)

### H1. Orphaned Python Subprocess on Cancellation
**File:** `TranscriptionService.swift:195-197`
**Issue:** Cancelling a transcription cancels the Swift Task but does NOT kill the Python process. It continues consuming CPU/GPU.
**Fix:** Add `process.terminate()` in `onTermination` handler.

### H2. deinit Missing Task Cleanup
**Files:** `ModelManager.swift:31`, `ChatViewModel.swift:87`
**Issue:** `deinit` logs but doesn't cancel `activeTasks` / `streamingTasks` / `transcriptionTasks`.
**Fix:** Cancel all active tasks in deinit.

### H3. Silent saveContext() Failures
**File:** `ChatViewModel.swift:732`
**Issue:** `try? modelContext.save()` silently swallows SwiftData errors. User data can be lost with no indication.
**Fix:** Replace with do/catch + `AppLogger.error()`.

### H4. 8+ Silent try? Without Logging
**Files:** `FileStorage.swift:51`, `ModelManager.swift:179`, `AppLogger.swift:85`, `TaskManager.swift:135`
**Issue:** File deletion, log rotation, save failures all suppressed silently.
**Fix:** Add `AppLogger.error()` to all `try?` paths.

### H5. String Concatenation in LLM Streaming Hot Path
**File:** `ChatViewModel.swift:342`
**Issue:** `accumulatedText += token` is O(n) per token. At 50-100 tokens/sec, causes UI stutter.
**Fix:** Batch token updates (every 50 chars or 100ms) before updating the message.

### H6. Excessive refreshConversations() Calls
**File:** `ChatViewModel.swift` (18+ call sites)
**Issue:** Every message, retry, or state change fetches ALL conversations from SwiftData. No filtering, no pagination.
**Fix:** Use SwiftUI `@Query` or add fetch limits. Only refresh when conversation list actually changes.

### H7. No Network Timeouts on LLM Requests
**Files:** `OpenAICompatibleService.swift`, `AnthropicService.swift`
**Issue:** Uses `URLSession.shared` with default 60s timeout. Hung server freezes the app.
**Fix:** Create configured `URLSession` with 30s timeout.

### H8. Data Race on TaskManager.activeTasks
**File:** `TaskManager.swift:19, 70-103`
**Issue:** Dictionary modified from Task contexts and MainActor without synchronization.
**Fix:** Consolidate access on MainActor.

### H9. Zombie Task in PythonEnvironment.runSetup()
**File:** `PythonEnvironment.swift:125-148`
**Issue:** `stderrTask` created but only weakly awaited. Can leak if process hangs.
**Fix:** Store task reference and ensure cancellation on error paths.

### H10. No Subprocess Timeout
**File:** `TranscriptionService.swift:171`
**Issue:** `process.waitUntilExit()` blocks indefinitely. Python subprocess can hang on GPU lock.
**Fix:** Add timeout (e.g., 30 minutes) with process kill on expiry.

---

## MEDIUM (Should Address)

### Architecture

**M1. ChatViewModel God Object** — 734 lines, 9+ responsibilities. Extract `TranscriptionOrchestrator` (~170 lines) and `ConversationNamingService` (~70 lines). `ChatViewModel.swift`

**M2. Services Without Protocols** — `TranscriptionService`, `PythonEnvironment`, `FileStorage` are static enums with no protocol. Cannot be mocked for unit tests.

**M3. TaskManager Post-Init Injection** — Should be constructor parameter, not mutable property set after init. `ChatViewModel.swift:78`, `ContentView.swift:110`

### Performance

**M4. MessageAnalysis Recomputed on Every Cell Render** — UTF-8 iteration on every render, not just on content change. `ChatView.swift:873`

**M5. MainActor.run() Per Token** — Every LLM token triggers a MainActor context switch. Should batch. `ChatViewModel.swift:340`

**M6. Blocking Directory Enumeration** — `ModelManager.directorySize()` on utility thread but called from `refreshStatuses()` which may run frequently. `ModelManager.swift:211`

### Data Integrity

**M7. No SwiftData Schema Versioning** — No migration strategy for future schema changes. Adding required fields breaks existing data.

**M8. Unvalidated Process Arguments** — User-editable `ct2PackageURL` and `ctranslate2SourcePath` passed to Process without validation. `PythonEnvironment.swift:94-117`

**M9. Race Condition on activeTranscriptionCount** — Concurrent completions can leave counter stuck. `ChatViewModel.swift:605, 671`

**M10. AppLogger Not Thread-Safe** — Race between `rotateIfNeeded()` and file write from multiple threads. `AppLogger.swift:44-68`

### UI/UX

**M11. Multiple .sheet Modifiers on ContentView** — Two `.sheet` on same view (setup + task manager). SwiftUI limitation: only one shows at a time. `ContentView.swift:131-142`

**M12. No Empty State for 0 Conversations** — Sidebar appears blank. New users confused about how to start. `ConversationListView.swift`

**M13. Font Scaling Breaks at >1.5x** — Some TextFields in Settings have hardcoded widths (60, 40, 80) that don't scale. `SettingsView.swift:57, 118, 134`

**M14. No Timeout on LLM Test Connection** — Can hang indefinitely. `SettingsView.swift:520-545`

**M15. Unicode Truncation in Auto-Title** — Character-boundary truncation can split multi-codepoint emoji. `ChatViewModel.swift:403-406`

### Missing Features (from TelegramSwift)

**M16. Audio Visibility-Aware Pause** — Player keeps playing when cell scrolls out of viewport. `ChatView.swift:1148`

**M17. Priority Queue for Transcriptions** — FIFO only, no user-initiated priority. `ChatViewModel.swift:559`

**M18. isCompatibleWithResponsiveScrolling** — Not set on NSTableView. Could improve perceived scroll smoothness. `ChatView.swift:203`

---

## LOW (Nice to Have)

| # | Issue | Location |
|---|-------|----------|
| L1 | Missing VoiceOver labels on buttons | Multiple views |
| L2 | Color-only model selection indicator | ModelManagerView.swift:62 |
| L3 | Inconsistent button styles across views | Multiple |
| L4 | AboutView defined inline in CTTranscriberApp.swift | CTTranscriberApp.swift:141 |
| L5 | ScaledFont defined in SettingsManager (UI concern in ViewModel) | SettingsManager.swift:1-45 |
| L6 | ChatMessageDTO naming — "DTO" uncommon in Swift | LLMService.swift:5 |
| L7 | fatalError on missing bundled defaults | SettingsStorage.swift:70 |
| L8 | sortedMessages() sorts in-memory on every call | ChatViewModel.swift:95 |
| L9 | Error comparison uses localizedDescription string matching | ChatViewModel.swift:354 |
| L10 | Timer leak risk in AudioPlaybackManager on app quit | AudioPlaybackManager.swift:108 |
| L11 | Progress text can overflow in EnvironmentSetupView | EnvironmentSetupView.swift:48 |
| L12 | No keyboard shortcut for Task Manager | ContentView.swift:49 |

---

## TelegramSwift Patterns — Adoption Status

### Fully Adopted (17 patterns)
NSTableView migration, scroll throttling (200ms), MessageAnalysis throttle (500 chars), height caching, diff-based updates, `layerContentsRedrawPolicy = .never`, background task processing, constructor DI, TaskManagerProtocol, transcription cleanup on delete, deinit logging, log rotation, expand/collapse scroll preservation, video aspect ratio caching, live resize height recalc, NSTextStorage height measurement, retry with error detection.

### Partially Adopted (4 patterns)
Queue isolation (uses Task.detached, not dedicated serial queues), constructor DI (TaskManager still post-init), keyboard event routing (basic), layout caching (missing explicit width tracking).

### Missed — Worth Implementing (4 patterns)
- **Subprocess timeout** — prevent hung processes (HIGH)
- **Priority queue for transcriptions** — user actions preempt auto-queue (MEDIUM)
- **Audio visibility-aware pause** — pause on scroll out (MEDIUM)
- **isDynamicContentLocked** — freeze rendering during rapid scroll (LOW)

### Missed — Not Needed Yet (4 patterns)
Object pooling, NSCache for thumbnails, responsive scrolling flag, state machine for scroll position.

---

## Top 10 Recommended Fixes (by impact/effort)

| Priority | Fix | Effort | Impact |
|----------|-----|--------|--------|
| 1 | Fix AppUninstaller command injection | 10 min | Security |
| 2 | Add `process.terminate()` on transcription cancel | 1 line | Prevents orphaned GPU processes |
| 3 | Add error logging to `saveContext()` | 5 min | Prevents silent data loss |
| 4 | Consolidate shared state mutations on MainActor | 30 min | Eliminates 3 data races |
| 5 | Clean up convertedName files on conversation delete | 5 min | Prevents disk space leak |
| 6 | Add network timeout to LLM URLSession | 5 min | Prevents app freezes |
| 7 | Batch LLM token updates (every 50 chars) | 15 min | Eliminates streaming stutter |
| 8 | Add subprocess timeout (30 min) | 15 min | Prevents hung transcriptions |
| 9 | Cancel active tasks in deinit | 10 min | Prevents task leaks |
| 10 | Extract TranscriptionOrchestrator from ChatViewModel | 1 hour | Architecture health |

---

## Resolution Status (2026-03-19)

Fixes applied in `reports/milestone-11b-audit-fixes.md`.

| Issue | Status |
|-------|--------|
| **C1** Command injection | FIXED — positional args |
| **C2** streamingConversationIDs race | FIXED — @MainActor |
| **C3** transcriptionTasks race | FIXED — @MainActor |
| **C4** Orphaned MP4 files | FIXED — delete convertedName |
| **H1** Orphaned Python process | FIXED — process.terminate() |
| **H2** deinit task cleanup | FIXED — @MainActor isolation |
| **H3** Silent saveContext | FIXED — error logging |
| **H4** Silent try? | FIXED — FileStorage, TaskManager |
| **H5** String concatenation | FIXED — 50-char batching |
| **H6** Excessive refreshConversations | FIXED — 6 calls removed |
| **H7** No network timeouts | FIXED — llmURLSession 30s/10min |
| **H8** TaskManager race | FIXED — @MainActor |
| **H9** Zombie stderrTask | MITIGATED — by H1 |
| **H10** Subprocess timeout | MITIGATED — by H1 |
| **M7** Schema versioning | FIXED — SchemaV1 + MigrationPlan |
| **M9** activeTranscriptionCount | FIXED — by C2 |
| **M10** AppLogger thread safety | FIXED — serial queue |
| **M12** Empty conversation state | FIXED — overlay |
| **M13** Font scaling Settings | FIXED — scaled widths |
| **M14** Test connection timeout | FIXED — by H7 |
| **L4** AboutView extraction | FIXED — own file |
| **L12** Task Manager shortcut | FIXED — Cmd+Shift+B |
| M1, M2, M4-M6, M8, M11, M15-M18 | DEFERRED |
| L1-L3, L5-L11 | DEFERRED |
