# Code Review Round 2 — Final Report

## Scope
~8,500 lines, 38 Swift files. 3 parallel review agents (swift-pro), all verified by lead.

## Findings: 3 HIGH, 8 MEDIUM, 20 LOW, 1 REJECTED, 2 DOWNGRADED
- 11 findings fixed (3 HIGH + 8 MEDIUM)
- 1 REJECTED (NSEvent.modifierFlags — synchronous handler)
- 2 DOWNGRADED (API key leak → MEDIUM, path traversal → LOW)
- 20 LOW — not fixed (code smells, defense-in-depth, unlikely triggers)

## Fixed Issues

### HIGH (3 fixed)
1. **Search cache not invalidated on searchText change** — `ChatViewModel.swift`
   - Added `_cachedSearchText` tracking; cache invalidated when search query changes
   - Root cause: @Observable stopped tracking `searchText` after first cache hit

2. **Video conversion Task not cancelled on deletion** — `ChatViewModel.swift`
   - Added `.convertingVideo` case to `ConversationActivity` enum
   - Video conversion Task registered in `activities` dict, cancelled on deletion
   - Added `Task.isCancelled` checks and `isDeleted`/`modelContext` validity guards
   - Changed `[self]` to `[weak self]` in MainActor.run closures

3. **Array index OOB crash in extendHighlight** — `ConversationListView.swift` + `ChatViewModel.swift`
   - Clamped `highlightCursor` after `deleteHighlightedConversations`
   - Added bounds check in `extendHighlight` as defense-in-depth

### MEDIUM (8 fixed)
4. **Auto-name no cancellation check** — Added `try Task.checkCancellation()` in stream loop + validity guard before writing title
5. **selectedConversationID stale after deletion** — Now selects first non-deleted conversation
6. **Export error swallowing** — JSON export shows error alert; PDF export shows failure message
7. **findMessage O(C×M)** — Added `conversationID` parameter for O(M) lookup; all 6 call sites updated
8. **ModelManager cancelDownload race** — Added guard to skip status update if task was already removed
9. **Temp ZIP leak on error** — Added `defer` block for ZIP cleanup
10. **Missing anthropic-version header** — Defaulted to `2023-06-01` if not provided in extraHeaders
11. **API key in error body** — Added regex-based redaction of Bearer/sk-/key patterns in LLMError descriptions

## Files Modified
- `CTTranscriber/ViewModels/ChatViewModel.swift` — Fixes 1,2,4,5,6,7
- `CTTranscriber/Views/ConversationListView.swift` — Fix 3
- `CTTranscriber/Services/ModelManager.swift` — Fix 8
- `CTTranscriber/Services/ConversationExporter.swift` — Fix 9
- `CTTranscriber/Services/LLM/AnthropicService.swift` — Fix 10
- `CTTranscriber/Services/LLM/LLMService.swift` — Fix 11

## Not Fixed (LOW — code smells / defense-in-depth)
- UncheckedSendableBox still defined (used by TaskManager)
- Force-unwrap autoTitleModel! (guarded by isEmpty check)
- Strong [self] captures in MainActor.run (app-lifetime object)
- DispatchQueue.main.async mixed with Swift concurrency (intentional)
- Auto-name after stopStreaming (minor UX)
- SettingsManager not @MainActor (all access is MainActor)
- MarkdownContentView ForEach identity (suboptimal, not a bug)
- Timer closure captures struct self (cleanup path correct)
- AttachmentView isUnsupportedVideo UX
- MessageBubble ForEach filter (trivial for small n)
- VideoConverter/ditto process on cancellation (process completes normally)
- AppLogger force-unwrap (virtually never fails on macOS)
- SettingsStorage try! (developer error only)
- Import doesn't restore attachments (feature gap)
