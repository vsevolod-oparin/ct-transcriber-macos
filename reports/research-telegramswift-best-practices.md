# Research: TelegramSwift Best Practices vs CT Transcriber

**Date:** 2026-03-17
**Scope:** Architecture, patterns, performance, code quality comparison

---

## Executive Summary

TelegramSwift is a 1265-file production macOS app built by experienced native developers. CT Transcriber is a 27-file SwiftUI app in early development. The comparison reveals **actionable improvements** across 6 areas: architecture, performance, state management, text rendering, scroll/table virtualization, and resource lifecycle. Many patterns from Telegram are overengineered for our scale — this report focuses on what's **practically adoptable**.

---

## 1. Architecture Comparison

### Telegram's Approach
- **Pure AppKit** — zero SwiftUI. Custom `View` → `NSView` hierarchy, `ViewController` → `NSViewController`, custom `NavigationViewController`, custom `TGSplitView`
- **Signal-based reactive state** (SwiftSignalKit) — functional reactive programming with `Signal<T, E>`, `Promise<T>`, `Disposable`, pipe operator `|>`
- **49 extracted packages** — each concern (UI, media, fetch, themes, settings) is a standalone Swift Package
- **Protocol-driven DI** — `FetchManager` is a protocol, managers injected via constructor

### CT Transcriber's Approach
- **SwiftUI + NSViewRepresentable** bridges for AppKit (NSTextView, NSTextField)
- **`@Observable` pattern** — modern Swift observation for ViewModels
- **Flat file structure** — 7 directories, no packages
- **Direct injection** — managers assigned as properties post-init

### Verdict & Recommendations

| Area | Telegram | CT Transcriber | Adopt? |
|------|----------|---------------|--------|
| UI Framework | Pure AppKit | SwiftUI + bridges | **No** — SwiftUI is fine for our scale; we already bridge where needed |
| Reactive System | SwiftSignalKit (custom FRP) | @Observable + async/await | **No** — Swift concurrency is the modern standard |
| Package extraction | 49 packages | Flat structure | **Partial** — extract Services into a local package when we hit ~50 files |
| Protocol-based services | FetchManager protocol | Concrete classes | **Yes** — add protocols for LLMService (already done), TranscriptionService, TaskManager |
| Constructor DI | All dependencies in init | Post-init assignment | **Yes** — move to init-based injection for testability |

**Priority action:** Add `TranscriptionServiceProtocol` and `TaskManagerProtocol` for testability. Move from post-init property assignment to constructor injection in ChatViewModel.

---

## 2. Performance: What Telegram Does That We Should Adopt

### 2.1 Table/List Virtualization (CRITICAL for chat at scale)

**Telegram:** Custom NSTableView with:
- `layerContentsRedrawPolicy = .never` — disables automatic layer redraws
- `usesAutomaticRowHeights = false` — all heights computed manually and cached
- `isCompatibleWithResponsiveScrolling = true` — async content rendering during scroll
- Cell reuse via identifier-based pool (`makeView(withIdentifier:)`)
- `TableUpdateTransition` with diff-based insert/update/delete (no full reload)
- `animateVisibleOnly` flag — only animates rows in viewport

**CT Transcriber:** SwiftUI `LazyVStack` inside `ScrollView` with:
- `.defaultScrollAnchor(.bottom)` + `.id(conversationID)` to recreate per conversation
- `onChange(of: lastContentLength)` fires on **every character** during streaming — potential jank
- No diff-based updates — SwiftUI handles it internally but without fine control

**Recommendations:**
1. **Throttle scroll-during-streaming** — scroll every 50 characters or 200ms, not every character
2. **Consider NSTableView migration for chat** — this was already identified as needed for Cmd+Down and expand/collapse scroll anchoring. Telegram proves NSTableView is the right choice for chat
3. **Pre-compute row heights** — our `MessageAnalysis` is a good start, but heights should be cached per message ID and only recomputed on width change

### 2.2 Image/Media Caching

**Telegram:** Multi-tier NSCache system:
- 7 segregated caches (avatars, photos, thumbnails, stickers, emoji, wallpaper, themes)
- NSCache with explicit limits (200-10000 items per cache)
- Separate high-quality vs thumbnail caches
- `CMSampleBuffer` caching for video frames
- `PhotoCacheKeyEntry` with content-aware hash keys (media ID + size + scale + flags)

**CT Transcriber:** No image caching layer. Attachments loaded from disk each time via `FileStorage`.

**Recommendations:**
1. **Add NSCache for attachment thumbnails** — when we add image/video preview, cache thumbnails in memory
2. **For audio waveforms** (future) — cache computed waveform data per attachment UUID

### 2.3 Layer & Animation Optimization

**Telegram:**
- `NullAction` CAAction to disable implicit Core Animation transitions
- Direct `layer.contents = image` instead of view redraw cycle
- `isDynamicContentLocked` flag to freeze rendering during scroll
- DisplayLink-based animation timing

**CT Transcriber:** Uses default SwiftUI animation system.

**Recommendations:**
1. **Add `isDynamicContentLocked` equivalent** — when `LargeTextView` (NSTextView) is inside a scrolling container, disable layout recalculation during rapid scroll
2. **For future audio waveform/player views** — use CALayer direct content setting, not SwiftUI redraws

### 2.4 Sticker/Media Visibility-Aware Loading

**Telegram:**
```swift
// Only play stickers when: window is key + view is visible + not scrolling
let accept = (self.window != nil && self.window!.isKeyWindow)
    && !NSIsEmptyRect(self.visibleRect)
    && !self.isDynamicContentLocked
```
Plus 250ms throttle to avoid rapid play/pause cycles.

**CT Transcriber:** Audio player `AVAudioPlayer` has no visibility awareness.

**Recommendation:** When implementing audio player seek bar (deferred M7b item), add visibility-based playback pause — stop audio preview if user scrolls past it.

---

## 3. State Management Comparison

### Telegram: Signal + Disposable Pattern
```swift
// Telegram: functional reactive
let signal = combineLatest(queue: prepareQueue,
    context.account.viewTracker.peerView(...),
    context.sharedContext.activeAccountsWithInfo,
    appearanceSignal
) |> map { ... -> TableUpdateTransition in
    return prepareEntries(left: previous.swap(entries), right: entries)
} |> deliverOnMainQueue

disposable.set(signal.start(next: { [weak self] transition in
    self?.genericView.tableView.merge(with: transition)
}))
```

### CT Transcriber: @Observable + async/await
```swift
// CT Transcriber: modern Swift
@Observable class ChatViewModel {
    var conversations: [Conversation] = []
    func sendMessage() async { ... }
}
```

### Verdict

Telegram's approach predates Swift concurrency and is more verbose but gives fine-grained control over threading. Our approach is correct for a modern app. However, Telegram has two patterns worth adopting:

1. **Queue assertions** — Telegram uses `assert(queue.isCurrent())` to catch threading bugs. We should add `@MainActor` assertions in critical paths:
   ```swift
   // Add to ChatViewModel methods that touch UI state
   assert(Thread.isMainThread, "Must be called on main thread")
   ```

2. **Disposable lifecycle** — Telegram explicitly cancels all subscriptions. Our `Task` objects in ChatViewModel's `transcriptionTasks` dictionary can leak if messages are deleted. **Fix:** clean up tasks when conversation is deleted.

---

## 4. Text Rendering

### Telegram: Custom TextNode + Layout Caching
- `TextNode.layoutText()` measures text once, caches `TextNodeLayout`
- Layout objects reused until width changes
- Compiled regex cached as static (`markdownRegex`)
- Adjacent text attributes merged to reduce rendering ops

### CT Transcriber: SwiftUI Text + NSTextView Bridge
- `MessageAnalysis` pre-computes line count via byte sampling (good)
- `LargeTextView` (NSTextView) for >5K chars with `allowsNonContiguousLayout` (good)
- But: `MessageAnalysis` recomputed via `task(id: message.content.count)` on every content change during streaming

### Recommendations

1. **Cache MessageAnalysis per message ID** — don't recompute on every streaming character. Recompute only when streaming finishes or every 500 chars
2. **Pre-compute collapsed preview once** — the `collapsedPreview` substring is recomputed on every render; cache it on the message
3. **Static regex compilation** — if we add markdown support, compile regex patterns once as `static let`

---

## 5. Scroll Position Preservation

### Telegram: ID-Based Scroll State Machine
```swift
public enum TableScrollState {
    case top(id: AnyHashable, innerId: AnyHashable?, animated: Bool, focus: TableScrollFocus, inset: CGFloat)
    case bottom(id: AnyHashable, innerId: AnyHashable?, animated: Bool, focus: TableScrollFocus, inset: CGFloat)
    case center(id: AnyHashable, ...)
    case saveVisible(TableSavingSide, Bool)
    case none(TableAnimationInterface?)
    case down(Bool)
    case up(Bool)
}
```
Scroll position saved by **message stable ID**, not by pixel offset. When loading older messages above, position is preserved relative to the visible message.

### CT Transcriber: Pixel-Based with ScrollViewReader
- `scrollTo(id, anchor:)` with `.bottom` anchor
- `.defaultScrollAnchor(.bottom)` for auto-scroll
- Known issues: Cmd+Down unreliable, expand/collapse breaks scroll

### Recommendations

1. **When migrating to NSTableView** (already planned), implement Telegram's ID-based scroll preservation
2. **For now:** the `.id(conversationID)` trick to recreate ScrollView per conversation is a reasonable workaround
3. **Add `saveVisible` equivalent** — before expanding/collapsing a message, save the first visible message ID, then scroll back to it after layout

---

## 6. Resource Lifecycle & Background Processing

### Telegram: Queue + Disposable + Pool
- **Object pooling** for `AVSampleBufferDisplayLayer` (expensive to create)
- **PreUploadManager** monitors file size on background queue, batches updates
- **FetchManager** with priority queue: `userInitiated > foregroundPrefetch > backgroundPrefetch`
- **Bag<T>** pattern for reference-counted subscriptions

### CT Transcriber: Task + TaskManager
- `BackgroundTask` SwiftData model for persistence (good)
- Crash recovery marks running tasks as failed (good, mirrors Telegram's crash detection)
- But: no priority system, no object pooling, no fetch batching

### Recommendations

1. **Add priority to transcription queue** — user-initiated (manual attach) should preempt auto-queued items
2. **Clean up transcription tasks on conversation delete** — currently `transcriptionTasks[messageID]` can leak
3. **Add timeout to Python subprocess** — Telegram's media player has timeouts; our `TranscriptionService` has none

---

## 7. Code Quality Patterns from Telegram

### 7.1 Theme Protocol (Adopt)
Telegram's `AppearanceViewProtocol`:
```swift
public protocol AppearanceViewProtocol {
    func updateLocalizationAndTheme(theme: PresentationTheme)
}
```
Every view implements this. Theme changes cascade without SwiftUI's environment.

**For us:** Not needed now (SwiftUI handles themes via `.preferredColorScheme`), but useful if we add custom themes beyond system/light/dark.

### 7.2 Transaction Handler (Consider)
```swift
public class TransactionHandler: NSObject {
    private var lock: OSSpinLock = 0
    public func execute() -> Bool { /* atomic */ }
}
```
**For us:** Not needed — Swift actors and `@MainActor` handle this.

### 7.3 Crash Detection (Already Have)
Telegram: checks timestamp file to detect crashes.
CT Transcriber: marks `.running` tasks as `.failed` on init — same principle, good.

### 7.4 Lite Mode (Future Consideration)
Telegram has `LiteMode` with granular feature flags:
```swift
public enum LiteModeKey: String {
    case emoji_effects, emoji, blur, dynamic_background, gif, video, stickers, animations
}
```
**For us:** Could add a "Low Power Mode" that reduces streaming frequency, disables animations, uses smaller models.

### 7.5 Deinit Debugging
Telegram adds breakpoint markers in deinit:
```swift
deinit {
    var bp: Int = 0
    bp += 1  // Set breakpoint here to track lifecycle
}
```
**For us:** Add `deinit` logging to ChatViewModel, TaskManager, and service objects to catch retain cycles.

---

## 8. What NOT to Adopt from Telegram

| Telegram Pattern | Why Skip |
|-----------------|----------|
| Pure AppKit (no SwiftUI) | SwiftUI gives us faster development, modern APIs, and is Apple's future |
| SwiftSignalKit (custom FRP) | async/await + @Observable is simpler and standard |
| OSSpinLock | Deprecated; Swift actors are better |
| 49 packages for 27 files | Overengineered for our scale |
| Custom navigation stack | SwiftUI NavigationSplitView works for our needs |
| ObjC bridging (HackUtils) | We don't need view hierarchy introspection |
| `var bp: Int = 0; bp += 1` deinit | Use `AppLogger.debug("deinit \(Self.self)")` instead |

---

## 9. Priority Action Items

### Immediate (Next Milestone)

| # | Action | Impact | Effort |
|---|--------|--------|--------|
| 1 | **Throttle scroll during streaming** — every 200ms or 50 chars, not every char | Eliminates scroll jank | Small |
| 2 | **Cache MessageAnalysis per message ID** — recompute only on stream end or every 500 chars | Reduces CPU during streaming | Small |
| 3 | **Add subprocess timeout** to TranscriptionService (e.g., 30 min) | Prevents hung processes | Small |
| 4 | **Clean up transcriptionTasks on conversation delete** | Prevents Task leaks | Small |
| 5 | **Move PythonEnvironment validation off main thread** | Eliminates startup freeze | Small |

### Medium-Term (M9-M10)

| # | Action | Impact | Effort |
|---|--------|--------|--------|
| 6 | **Migrate chat to NSTableView** | Fixes scroll issues, enables Telegram-level performance | Large |
| 7 | **Add protocols for services** (TranscriptionServiceProtocol, TaskManagerProtocol) | Testability | Medium |
| 8 | **Constructor-based DI** for ChatViewModel | Testability, clearer dependencies | Medium |
| 9 | **Add NSCache for thumbnails/previews** | Memory-efficient media display | Medium |
| 10 | **Log rotation** for AppLogger (max 10MB, keep 3) | Prevents disk bloat | Small |

### Future (Post-M11)

| # | Action | Impact | Effort |
|---|--------|--------|--------|
| 11 | **Priority queue for transcriptions** | Better UX for manual vs auto tasks | Medium |
| 12 | **Lite Mode / Low Power** settings | Battery life on laptops | Medium |
| 13 | **Extract Services into Swift Package** | Clean architecture at scale | Large |
| 14 | **ID-based scroll state preservation** (with NSTableView) | Perfect scroll behavior | Large |

---

## 10. Key Metrics Comparison

| Metric | TelegramSwift | CT Transcriber |
|--------|--------------|----------------|
| Swift files | 1,265 | 27 |
| UI framework | AppKit (2014+) | SwiftUI (2019+) |
| Reactive system | SwiftSignalKit (custom) | @Observable + async/await |
| Persistence | Postbox (custom DB) | SwiftData |
| Packages/modules | 49 | 0 |
| Table implementation | NSTableView (custom) | LazyVStack (SwiftUI) |
| Image caching | 7 NSCache instances | None |
| Thread safety | Queue + OSSpinLock + assertions | @MainActor + Task |
| Text rendering | Custom TextNode + layout cache | SwiftUI Text + NSTextView bridge |
| Media playback | Custom state machine + pools | AVAudioPlayer (basic) |
| Test infrastructure | Not visible in packages | UI tests (regressed) |

---

## Conclusion

TelegramSwift is a masterclass in **AppKit performance optimization** — every layer is hand-tuned for 60fps scrolling with thousands of messages. However, much of its complexity exists because it predates modern Swift features (async/await, @Observable, SwiftUI).

**For CT Transcriber, the highest-value takeaways are:**
1. **NSTableView for chat** (already planned) — this is the single biggest improvement
2. **Throttle streaming updates** — easy win, big impact
3. **Cache computed layouts** — MessageAnalysis is the right idea, just needs better invalidation
4. **Subprocess timeout** — basic reliability improvement
5. **Protocol-based services** — testability foundation

The app's architecture is fundamentally sound for its scale. The SwiftUI + @Observable stack is the right choice. Focus on the 5 immediate items and plan NSTableView migration as the major performance milestone.
