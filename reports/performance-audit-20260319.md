# CT Transcriber macOS — Performance Audit Report

## Executive Summary
Comprehensive audit of all specified code found **12 performance issues** across multiple categories: streaming string concatenation, excessive refreshConversations() calls, file I/O inefficiencies, missing network timeouts, and suboptimal text rendering. Most issues manifest during real-world usage with large conversations or sustained LLM streaming.

---

## Critical Issues

### 1. **String Concatenation in LLM Streaming Hot Path** — CRITICAL
**File:** CTTranscriber/ViewModels/ChatViewModel.swift:342  
**Severity:** CRITICAL  
**Impact:** Every token received from LLM requires a full string reallocation. At 50–100 tokens/sec, this causes visible UI lag.

```swift
for try await token in stream {
    guard let self, !Task.isCancelled else { break }
    accumulatedText += token  // ← Line 342: O(n) operation per token
    await MainActor.run {
        assistantMessage.content = accumulatedText
    }
}
```

**Problem:**  
- Each `+=` with a String is O(n) — reallocates and copies entire accumulated text
- For a 10KB response (typical), this performs ~10,000 allocations
- Pushes UI update on MainActor after EVERY token

**User Impact:** Stuttering, jank during streaming, CPU spikes

**Fix:** Use NSMutableString or StringBuilder pattern; batch updates every 200ms

---

### 2. **Excessive refreshConversations() After Every State Change** — CRITICAL
**File:** CTTranscriber/ViewModels/ChatViewModel.swift (multiple locations)  
**Severity:** CRITICAL  
**Lines:** 105, 157, 179, 223, 238, 252, 259, 289, 309, 323, 378, 462, 508, 542, 556, 575, 591, 600, 677

```swift
func sendMessage() {
    ...
    conversation.messages.append(userMessage)
    conversation.updatedAt = Date()
    messageText = ""
    lastError = nil
    saveContext()
    refreshConversations()  // ← Fetches ALL conversations from database every time
    
    requestLLMResponse(for: conversation)
}
```

**Problem:**  
- Called 18+ times across the ViewModel
- **Each call fetches ALL conversations** from SwiftData: `modelContext.fetch(descriptor)`
- Happens after every message, every retry, every conversation switch
- No predicate filtering — scans entire database

**User Impact:** Noticeable lag when you have 100+ conversations. Kills responsiveness during streaming.

**Fix:** 
- Use `@Query` in SwiftUI for reactive updates instead of manual fetch
- Batch database writes before calling `refreshConversations()`
- Only fetch conversations once at startup; maintain in-memory sorted array

---

### 3. **Wasteful Directory Size Calculation on Main Thread (Blocking)** — HIGH
**File:** CTTranscriber/Services/ModelManager.swift:211–224

```swift
private static func directorySize(path: String) -> Int {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
    var totalBytes: Int64 = 0
    while let file = enumerator.nextObject() as? String {
        let fullPath = (path as NSString).appendingPathComponent(file)
        if let attrs = try? fm.attributesOfItem(atPath: fullPath),
           let size = attrs[.size] as? Int64 {
            totalBytes += size
        }
    }
    ...
}
```

**Problem:**  
- Called during model refresh (lines 52–58) to get model size
- Runs on main thread via `Task.detached()` but blocks refreshStatuses()
- For a 3GB model directory, enumerates **thousands of files**
- Each file gets a separate `attributesOfItem()` call = multiple syscalls

**User Impact:** UI freeze when opening Models settings (100ms–1s lag)

**Fix:** 
- Run on `.utility` priority background queue
- Cache model size; invalidate only when files change
- Use more efficient API (e.g., FileManager recursive size API)

---

## High-Priority Issues

### 4. **MessageAnalysis Recomputation on Every Render (Not Just Streaming)** — HIGH
**File:** CTTranscriber/Views/ChatView.swift:873–881 (MessageBubble body)

```swift
.task(id: message.content.count) {
    // Throttle analysis recomputation during streaming
    let currentLength = message.content.count
    let delta = abs(currentLength - lastAnalyzedLength)
    if analysis == nil || !isStreamingThis || delta >= Self.analysisRecomputeThrottle {
        analysis = MessageAnalysis(content: message.content)
        lastAnalyzedLength = currentLength
    }
}
```

**Problem:**  
- Task is triggered whenever `message.content.count` changes
- But `currentAnalysis` computed property (line 822) **creates a new MessageAnalysis if nil** every view render
- This means: every time the table reloads a cell (scroll, expand/collapse), MessageAnalysis is recomputed
- MessageAnalysis does expensive UTF-8 iteration for 4KB+ strings (lines 748–787)

**User Impact:** Scroll stuttering with large conversations (1000+ messages)

**Fix:** 
- Cache at message level in SwiftData, not in @State
- Only recompute on explicit content change

---

### 5. **No Request Timeouts for LLM Network Requests** — HIGH
**File:** CTTranscriber/Services/LLM/OpenAICompatibleService.swift:42 & AnthropicService.swift:49  
**Severity:** HIGH

```swift
let (bytes, response) = try await URLSession.shared.bytes(for: request)
```

**Problem:**  
- Uses `URLSession.shared` with **no custom configuration**
- **Default timeout is 60 seconds**, but no explicit timeout for streaming
- If network hangs, user's streaming request blocks indefinitely
- No connection pool configuration = each request might create new connection

**User Impact:** If network is unstable, streaming can freeze for 60s+ with no user feedback

**Fix:**
- Create URLSessionConfiguration with timeoutIntervalForRequest = 30s
- Add timeoutIntervalForResource for overall request duration
- Implement explicit timeout handling in stream loop

---

### 6. **Excessive MainActor.run() in Tight Loops During Streaming** — HIGH
**File:** CTTranscriber/ViewModels/ChatViewModel.swift:340–346

```swift
for try await token in stream {
    guard let self, !Task.isCancelled else { break }
    accumulatedText += token
    await MainActor.run {  // ← Called 50–100+ times per second
        assistantMessage.content = accumulatedText
    }
}
```

**Problem:**  
- Every single token triggers a MainActor context switch
- MainActor queue becomes saturated
- Each update invalidates SwiftUI view graph
- No batching or throttling

**User Impact:** Main thread stalls, all UI feels sluggish during streaming

**Fix:**
- Batch updates: collect 200ms worth of tokens, then do single MainActor.run()
- Use a Timer or manual time tracking to throttle updates
- See: ChatTableView.Coordinator.scrollToBottomThrottled() (line 661) for correct pattern

---

### 7. **Text Preview Computation on Every Render (Not Just Long Messages)** — MEDIUM
**File:** CTTranscriber/Views/ChatView.swift:775–787 (MessageAnalysis.init)

```swift
if isLong {
    var lines: [Substring] = []
    var remaining = content[...]
    for _ in 0..<collapsedPreviewLines {
        if let newline = remaining.firstIndex(of: "\n") {
            lines.append(remaining[..<newline])
            remaining = remaining[remaining.index(after: newline)...]
        } else {
            lines.append(remaining)
            break
        }
    }
    collapsedPreview = lines.joined(separator: "\n") + "\n..."
}
```

**Problem:**  
- Even when a message is NOT expanded, computing the preview is wasteful
- For a 100KB message, `firstIndex(of: "\n")` scans the entire string prefix repeatedly
- Only used if isLong && !isExpanded && !isStreamingThis

**User Impact:** Minor lag during scroll for very large transcripts

**Fix:**
- Only compute preview when `isLong` AND `isExpanded` is false at display time
- Cache preview alongside error/timestamp detection

---

## Medium-Priority Issues

### 8. **Inefficient Timestamp Detection Using utf8.count** — MEDIUM
**File:** CTTranscriber/Views/ChatView.swift:745

```swift
hasTimestamps = content.utf8.count > 5 && content.contains("[") && content.contains("→")
```

**Problem:**  
- `content.utf8.count` iterates entire string to count UTF-8 bytes (O(n))
- Should just check if string is long enough using `.count`
- Called during every MessageAnalysis creation
- For 100KB message, this is a full scan for a simple length check

**User Impact:** Negligible for average messages, noticeable with 1000+ message transcripts

**Fix:** Replace `content.utf8.count > 5` with `content.count > 5`

---

### 9. **Process Creation Overhead Not Pooled** — MEDIUM
**Files:**  
- CTTranscriber/Services/TranscriptionService.swift:79 (per transcription)
- CTTranscriber/Services/ModelManager.swift:102 (per model download)
- CTTranscriber/Services/PythonEnvironment.swift:198, 220 (per env check)
- CTTranscriber/Services/VideoConverter.swift:40 (per video conversion)

```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: pythonPath)
process.arguments = args
try process.run()
```

**Problem:**  
- Each transcription/conversion spawns a fresh Process()
- Process creation is expensive: subprocess initialization, Python startup, etc.
- No connection pooling or reuse
- Multiple concurrent transcriptions = multiple Process instances

**User Impact:** High memory usage and CPU spikes during concurrent operations

**Fix:**
- For sequential operations: no issue
- For concurrent: consider persistent Python worker subprocess

---

### 10. **No Row Height Cache Invalidation on Window Resize (Before Fix in viewDidEndLiveResize)** — MEDIUM
**File:** CTTranscriber/Views/ChatView.swift:284–301

```swift
if abs(fontScale - oldFontScale) > 0.01, let tableView = coordinator.tableView {
    coordinator.heightCache.removeAll()
    tableView.intercellSpacing = NSSize(width: 0, height: 12 * fontScale)
    tableView.reloadData()
    // Second pass...
    DispatchQueue.main.async {
        coordinator.heightCache.removeAll()
        let allRows = IndexSet(integersIn: 0..<coordinator.messages.count)
        tableView.noteHeightOfRows(withIndexesChanged: allRows)
        tableView.reloadData()  // ← Second full reload
    }
}
```

**Problem:**  
- On font scale change, does **full reloadData() twice**
- This remeasures ALL row heights (expensive for 1000+ messages)
- Better approach: invalidate only affected rows

**User Impact:** Lag when changing font scale with large conversations

**Fix:**
- One reload with invalidated cache is sufficient
- Use `noteHeightOfRows(withIndexesChanged:)` first, then reload

---

### 11. **Audio Player Creates Timer in Every Player Instance** — MEDIUM
**File:** CTTranscriber/Views/ChatView.swift:1306–1318 (AudioPlayerView.startTimer)

```swift
private func startTimer() {
    timer = Timer.scheduledTimer(withTimeInterval: Self.progressUpdateInterval, repeats: true) { _ in
        guard let player, !isDragging else { return }
        currentTime = player.currentTime
        AudioPlaybackManager.shared.currentTime = currentTime
        if !player.isPlaying {
            isPlaying = false
            persistPosition()
            stopTimer()
            AudioPlaybackManager.shared.didFinishPlaying(storedName: attachment.storedName)
        }
    }
}
```

**Problem:**  
- Every AudioPlayerView creates its own Timer (0.1s interval)
- On scroll, many off-screen players may have timers
- If 10 audio cells are in memory, that's 10 timers firing 10x/sec
- No aggregation or shared timer

**User Impact:** CPU usage spikes when many audio attachments are on-screen

**Fix:**
- Use AudioPlaybackManager's existing timer (already at 0.2s interval)
- Only update the currently playing player

---

### 12. **AVAsset Metadata Loaded Synchronously in Player (Not Blocking Main, But Inefficient)** — MEDIUM
**File:** CTTranscriber/Views/ChatView.swift:1236–1258 (AudioPlayerView.loadMetadata)

```swift
private func loadMetadata() {
    let url = FileStorage.url(for: attachment.storedName)
    do {
        let p = try AVAudioPlayer(contentsOf: url)  // ← Synchronous, can be slow
        duration = p.duration
        player = p
        ...
    }
    
    if attachment.kind == .video {
        Task.detached(priority: .utility) {
            let thumb = await Self.generateThumbnail(url: url)
            await MainActor.run { videoThumbnail = thumb }
        }
    }
}
```

**Problem:**  
- AVAudioPlayer init is synchronous and can block if file is on slow storage
- Thumbnail generation is detached (good), but metadata load is not
- Called when user clicks play (interactive)

**User Impact:** Slight lag on first playback click

**Fix:**
- Move metadata load to background task (similar to video thumbnail)

---

## Summary Table

| # | File | Line | Severity | Issue | User Impact |
|---|------|------|----------|-------|-------------|
| 1 | ChatViewModel.swift | 342 | CRITICAL | String += in streaming loop | Stuttering during token streaming |
| 2 | ChatViewModel.swift | 105,157,... | CRITICAL | refreshConversations() 18+ times | Lag with 100+ conversations |
| 3 | ModelManager.swift | 211 | HIGH | Blocking directory enumeration | 100ms–1s freeze on settings open |
| 4 | ChatView.swift | 873 | HIGH | MessageAnalysis recomputation | Scroll jank with large conversations |
| 5 | LLM Services | 42,49 | HIGH | No network timeouts | 60s freeze on network hang |
| 6 | ChatViewModel.swift | 340 | HIGH | MainActor.run() per token | Main thread saturation during streaming |
| 7 | ChatView.swift | 775 | MEDIUM | Wasteful preview computation | Scroll lag in transcripts |
| 8 | ChatView.swift | 745 | MEDIUM | utf8.count for length check | Minor lag in large conversations |
| 9 | Multiple | Various | MEDIUM | Process creation overhead | Memory/CPU spikes during concurrent tasks |
| 10 | ChatView.swift | 284 | MEDIUM | Double reloadData() on font change | Lag when adjusting text size |
| 11 | ChatView.swift | 1306 | MEDIUM | Timer per audio player | CPU spikes with many audio attachments |
| 12 | ChatView.swift | 1236 | MEDIUM | Sync metadata load | Minor lag on first playback |

---

## Recommendations (Priority Order)

1. **Fix streaming string concatenation** — 5–10 minute fix, huge impact
2. **Replace refreshConversations() with @Query** — 30 minute refactor, eliminates ~80% of DB traffic
3. **Add network timeouts** — 5 minute fix, prevents 60s+ freezes
4. **Batch MainActor updates during streaming** — 10 minute fix, smooths UI
5. **Cache MessageAnalysis at model level** — 20 minute fix, eliminates redundant computation
6. **Move directorySize to background queue** — 2 minute fix, removes main thread block
7. **Fix Audio player timers** — Use shared timer, 10 minute fix

All other issues are lower priority for typical usage patterns but should be addressed in refactoring passes.

