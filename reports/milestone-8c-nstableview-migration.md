# Milestone 8c: NSTableView Chat Migration

**Date:** 2026-03-17
**Status:** Complete

---

## What Was Done

### Core Migration

Replaced the SwiftUI `ScrollView` + `LazyVStack` message list with an `NSTableView` wrapped in `NSViewRepresentable`. This fixes all known scroll issues from LazyVStack's inability to know total content height.

**New components in ChatView.swift:**
- `ChatTableView: NSViewRepresentable` — hosts an NSScrollView containing NSTableView
- `ChatNSTableView: NSTableView` — subclass that passes keyboard events (Cmd+Up/Down) to SwiftUI
- `Coordinator` — implements `NSTableViewDelegate` + `NSTableViewDataSource`, manages all state

### Cell Rendering

Each row is an `NSHostingView` wrapping the existing SwiftUI `MessageBubble` view. This reuses all existing bubble UI (styling, context menus, attachments, copy button, etc.) without rewriting in AppKit.

Cell width is pre-set to match the table column width on creation, preventing a flash from narrow-to-wide during initial layout.

### Height Caching

Row heights are cached per message ID in `heightCache: [UUID: CGFloat]`. Cache is invalidated when:
- Table width changes (window resize)
- Message content changes (streaming)
- Expand/collapse toggle

**Large expanded messages** (>5K chars) use direct `NSTextStorage` + `NSLayoutManager` measurement instead of NSHostingView `fittingSize`, because the nested `LargeTextView` (NSViewRepresentable inside NSHostingView) doesn't report correct height through the Auto Layout measurement path.

Streaming rows are never cached — they change every token.

### Diff-Based Updates

Three update paths based on what changed:

1. **Same message IDs, streaming active** — reload only the last row + throttled scroll (200ms)
2. **Messages appended** (most common — new message sent, transcription placeholder) — `insertRows(at:)` with `.slideDown` animation
3. **General change** (deletions, reorders) — full `reloadData()`

### Expand/Collapse

`isExpanded` state moved from SwiftUI `@State` to the coordinator's `expandedMessages: Set<UUID>`. This survives cell reuse and is controlled by the coordinator.

On toggle:
1. Update the existing cell's content **in place** (swap NSHostingView rootView) — no cell reload = no flash
2. Animate only the height change (0.25s)
3. **Preserve exact scroll position** — saves `scrollView.contentView.bounds.origin` before the height change, restores it after. The viewport stays pinned; the bubble grows/shrinks downward.

### Scroll Commands

- **Cmd+Down** — `scrollRowToVisible(lastRow)` — reliable, no height estimation needed
- **Cmd+Up** — `scrollRowToVisible(0)`
- **Conversation switch** — full reload + scroll to bottom
- **Streaming** — throttled scroll every 200ms via `scrollToBottomThrottled()`
- **New message** — scroll to bottom with animation

### Performance Settings (from TelegramSwift)

- `layerContentsRedrawPolicy = .never` — no automatic layer redraws
- `selectionHighlightStyle = .none` — no selection chrome
- `intercellSpacing = NSSize(width: 0, height: 12)` — matches original LazyVStack spacing

---

## Files Modified

- **`ChatView.swift`** — Major rewrite of message list section:
  - Removed: `MessageListView` (SwiftUI ScrollView + LazyVStack)
  - Added: `ChatTableView` (NSViewRepresentable), `ChatNSTableView`, `Coordinator`
  - Modified: `MessageBubble` — `isExpanded` changed from `@State` to parameter
  - Simplified: `LargeTextView` — removed `onLayoutComplete` callback (NSTableView handles scroll)

---

## Issues Fixed

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| Cmd+Down unreliable | LazyVStack doesn't know total content height | NSTableView `scrollRowToVisible(lastRow)` |
| Expand/collapse scroll drift | LazyVStack can't preserve position during height change | Save/restore `bounds.origin` around height change |
| Scroll stutter during streaming | `onChange` fired per character | 200ms throttle in coordinator |
| Flash on expand/collapse | Cell destroyed and recreated | In-place content update (no reload) |
| Large expanded message gap | NSHostingView `fittingSize` wrong for nested NSViewRepresentable | Direct NSTextStorage height measurement |
| Initial narrow width | Table bounds not established during first layout | Don't cache heights when width < 300; pre-set cell frame width |
