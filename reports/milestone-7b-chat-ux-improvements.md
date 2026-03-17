# Milestone 7b: Chat UX Improvements

**Date:** 2026-03-17
**Status:** Complete (with known scroll issues documented)

---

## What Was Done

### Collapsible Bubbles
- Messages >15 lines auto-collapse, show 5 preview lines + "Show more (~N lines)"
- Line count estimated via sampling (first 4KB) for large messages — shows "~1,577" not "16"
- Click to expand/collapse; "Show more" button white on user bubbles, accent on assistant
- Large expanded messages (>5K chars) use `LargeTextView` (NSTextView) instead of SwiftUI Text

### Large Text Rendering (NSTextView)
- `LargeTextView` NSViewRepresentable for messages >5K characters
- `allowsNonContiguousLayout = true` — only lays out visible text
- Full content rendered (no truncation), selectable
- `sizeThatFits` reports actual rendered height to SwiftUI
- Length-first comparison in `updateNSView` avoids O(n) string comparison

### MessageAnalysis Cache
- Pre-computes `isError`, `lineCount`, `isLong`, `collapsedPreview`, `hasTimestamps` once per content change
- Early-exit newline counting on UTF-8 bytes
- Sampling-based line estimation for large strings (>4KB)
- Recomputed via `.task(id: content.count)` only when content length changes

### Bubble Copy
- Copy button appears on hover — left of user messages, right of assistant
- Uses `opacity` toggle (not conditional view) to prevent layout shift
- Right-click context menu: "Copy" and "Copy without timestamps"

### Audio Player
- Play/pause button on audio/video attachments
- AVAudioPlayer inline playback

### Message Status & Retry
- LLM errors kept as messages with ⚠ prefix, red-tinted background
- Error icon + "Retry" button in timestamp row + context menu
- `retryMessage()` deletes failed message and re-triggers

### LLM API Key Test
- "Test Connection" button sends minimal request ("Hi", max_tokens=1)
- Shows spinner → green checkmark or red error inline
- Resets when switching providers

### Message Input
- Scrollable TextEditor (replaces TextField)
- Grows 1-5 lines, scrolls beyond
- Placeholder aligned with cursor baseline

### Scroll Behavior
- `.defaultScrollAnchor(.bottom)` + `.id(conversationID)` — conversations start at bottom
- Cmd+Up scrolls to first message (works reliably)
- Cmd+Down scrolls to last message (unreliable — LazyVStack limitation)
- Auto-scroll during streaming

### Performance
- `MessageAnalysis` struct avoids recomputing on every render
- NSTextView with non-contiguous layout for large text
- Content change detection via `.count` (O(1)) not full string comparison
- Auto-scroll only during streaming

---

## Known Issues

1. **Cmd+Down / scroll-to-bottom**: unreliable with LazyVStack. Lazy height estimation causes overshoot. Pressing Cmd+Down twice usually works.
2. **Expand large message**: shifts scroll position because content height changes dramatically after expand. Post-layout scroll correction is unreliable with LazyVStack.
3. **Root cause**: LazyVStack doesn't know total content height upfront. Fix requires migrating the message list to NSTableView with `usesAutomaticRowHeights`.

---

## Files Modified

- `Views/ChatView.swift` — major rewrite: collapsible bubbles, LargeTextView, MessageAnalysis, copy button, audio player, retry, scroll behavior, TextEditor input
- `ViewModels/ChatViewModel.swift` — retryMessage(), error messages in chat
- `Views/SettingsView.swift` — Test Connection button, single-line API key
