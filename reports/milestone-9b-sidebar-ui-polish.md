# Milestone 9b: Sidebar & UI Polish

**Date:** 2026-03-18
**Status:** Complete

---

## What Was Done

### Sidebar Multi-Select & Navigation

Replaced SwiftUI `List(selection:)` single-selection with manual highlight management:

- **`highlightedIDs: Set<UUID>`** — tracks selected conversations (visual highlight)
- **`selectedConversationID: UUID?`** — tracks the active conversation (shown in detail)
- **Click** — highlights + enters conversation immediately, reclaims sidebar focus
- **Arrow Up/Down** — moves highlight only (doesn't enter), Cmd+Arrow scrolls chat
- **Shift+Arrow / Shift+Click** — extends selection range
- **Cmd+Click** — toggles individual item in multi-select
- **Enter** — activates highlighted conversation + focuses input
- **Backspace** — confirmation dialog, deletes all highlighted conversations
- **Tab** — toggles focus between sidebar and input (detects via `NSTextView` responder check)
- **Double-click title text** — inline rename (uses `NSApp.currentEvent?.clickCount`, no delay)
- **Double-click toolbar title** — inline rename via `TitleRenameField` (NSViewRepresentable for stable focus)

### Font Scaling

Global font scaling system:

- **`ScaledFont` struct** — `.body`, `.headline`, `.caption`, `.caption2`, `.title`, `.title2`, `.title3` computed from `NSFont.systemFontSize * fontScale`
- **`fontScale` environment key** — propagated to all views including NSHostingView cells
- **Cmd+Plus/Minus/0** — menu bar commands to increase/decrease/reset
- **Settings slider** — 70% to 200% with percentage display and Reset button
- All views updated: ChatView, ConversationListView, SettingsView, TaskManagerView, empty states
- NSTextView fonts (LargeTextView, TitleRenameField) scale
- Paddings, spacings, intercell spacing scale proportionally
- Settings window frame scales
- Persisted in `settings.json`

### Appearance Improvements

- Assistant bubble: `unemphasizedSelectedContentBackgroundColor` (better light mode contrast)
- Timestamps, filenames: `.primary` foreground (was faint `.secondary`/`.tertiary`)
- Custom empty states replace `ContentUnavailableView` (scales with font)
- Task manager: focus ring disabled, Enter/Escape close sheet

### NSTableView Performance (TelegramSwift Audit)

Based on code review of TelegramSwift's TableView.swift:

- **Height caching** — `heightCache: [UUID: CGFloat]` eliminates ~90% of `NSHostingController` allocations during scroll
- **Targeted invalidation** — cache cleared only for affected rows on content change, expand/collapse, font scale, resize
- **Resize via `viewDidEndLiveResize`** — matches Telegram pattern, no mid-resize updates
- **`isLiveResizing` flag** — suppresses `updateNSView` during drag
- **First render fix** — initial data set in `makeNSView` + deferred `reloadData`

---

## Files Created/Modified

- **Modified:** `ConversationListView.swift` — multi-select, keyboard navigation, rename, focus management
- **Modified:** `ChatView.swift` — font scaling throughout, mini-player, TitleRenameField, NSTableView perf
- **Modified:** `ChatViewModel.swift` — `highlightedIDs`, `highlightCursor`, `moveHighlight`, `scrollToTop/Bottom`
- **Modified:** `ContentView.swift` — Tab handler, Cmd+Up/Down, sidebar focus helper, custom empty state
- **Modified:** `CTTranscriberApp.swift` — font commands, `dynamicTypeSize`, Settings font environment
- **Modified:** `SettingsManager.swift` — `ScaledFont`, `fontScale` environment key, increase/decrease methods
- **Modified:** `SettingsView.swift` — font slider, all fonts scaled
- **Modified:** `TaskManagerView.swift` — scaled fonts, focus management
- **Modified:** `AppSettings.swift` — `fontScale` property
- **Modified:** `default-settings.json` — `fontScale: 1.0`
