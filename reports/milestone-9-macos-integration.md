# Milestone 9: macOS Integration

**Date:** 2026-03-17
**Status:** Complete

---

## What Was Done

### Document Type Registration

Created `CTTranscriber/Resources/Info.plist` with `CFBundleDocumentTypes` declaring the app as a Viewer (Alternate rank) for:

**Audio:** `public.audio`, `public.mp3`, `com.apple.m4a-audio`, `com.microsoft.waveform-audio`, `org.xiph.flac`, `public.aiff-audio`, `com.apple.coreaudio-format`

**Video:** `public.movie`, `public.mpeg-4`, `com.apple.quicktime-movie`, `public.avi`

`LSHandlerRank: Alternate` ensures the app appears in "Open With" menus without hijacking default file handlers (e.g., QuickTime, Music).

Switched from `GENERATE_INFOPLIST_FILE: true` to explicit `INFOPLIST_FILE` in project.yml.

### Single-Window File Open (AppDelegate)

Initial approach used SwiftUI `onOpenURL` on `WindowGroup`, but this created a new window for every file open. Fixed by using `NSApplicationDelegate`:

- `AppDelegate` implements `application(_:open urls:)` — the native macOS callback for file-open events
- URLs are queued in `@Published var pendingOpenURLs` and picked up by ContentView via `@ObservedObject`
- `applicationShouldHandleReopen` brings existing window to front on Dock click
- "New Window" removed from File menu via `.commands { CommandGroup(replacing: .newItem) { } }`

ContentView processes pending URLs:
1. On initial `.task {}` — handles files that arrived before ViewModel was ready
2. On `.onChange(of: appDelegate.pendingOpenURLs)` — handles files arriving after startup

### openFiles(urls:) — New Conversation from Files

`ChatViewModel.openFiles(urls:)`:
1. Creates a new `Conversation` titled from the first filename (e.g., "interview (+2 more)")
2. Selects the conversation
3. Attaches each file via the existing `attachFile(from:to:)` method
4. Audio/video files auto-transcribe as usual

### Drag-and-Drop (3 targets)

**Chat message area (NSTableView):** Native `NSTableViewDataSource` drag delegate — `validateDrop` returns `.copy` for file URLs, `acceptDrop` reads URLs from `NSDraggingInfo.draggingPasteboard` and calls `onDropFiles` callback. SwiftUI `.onDrop` doesn't work on NSTableView (AppKit consumes the event), so native drag handling was required.

**Input bar (TextEditor):** SwiftUI `.onDrop(of: [.fileURL])` on the TextEditor. Without this, dropping a file onto the input bar pastes the file path as text. The drop handler intercepts the event and calls `attachFile` instead.

**Empty state:** When no conversation is selected, `.onDrop` on `ContentUnavailableView` creates a new conversation via `openFiles(urls:)`. Uses `DispatchGroup` to collect all URLs from providers before creating the conversation.

### Content-Change Detection Fix (SwiftData Reference Bug)

During development, discovered that transcription results appeared collapsed (showing only the header) when opened via "Open With". Root cause: SwiftData `Message` objects are reference types. The coordinator's `oldMessages` and `messages` arrays pointed to the same objects, so in-place content updates (placeholder → final transcript) were invisible to the diff.

Fixed by adding `contentLengthSnapshot: [UUID: Int]` — a value-type copy of each message's content length. On each `updateNSView`, content lengths are compared against the snapshot to detect real changes and trigger row height recalculation.

---

## Files Created/Modified

- **Created:** `CTTranscriber/Resources/Info.plist` — document type declarations for audio and video
- **Modified:** `project.yml` — switched to explicit INFOPLIST_FILE
- **Modified:** `CTTranscriberApp.swift` — `AppDelegate` with `application(_:open:)`, `applicationShouldHandleReopen`, "New Window" removed
- **Modified:** `ContentView.swift` — `@ObservedObject appDelegate`, `processPendingURLs()`, empty-state drop handler
- **Modified:** `ChatView.swift` — NSTableView drag delegate (`validateDrop`/`acceptDrop`), input bar `.onDrop`, `contentLengthSnapshot` for change detection
- **Modified:** `ChatViewModel.swift` — `openFiles(urls:)` method

---

## Deferred

- **Share extension** — "Open in CT Transcriber" in Finder share menu. Requires a separate target, app group, and XPC communication. Low priority since "Open With" covers the primary use case.
