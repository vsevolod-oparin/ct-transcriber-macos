# CT Transcriber — Release Notes

---

## v0.5.3 (2026-04-29)

### Crash Fix
- Fixed `EXC_BREAKPOINT` crash in `Message.content.getter` when accessing deleted SwiftData objects during SwiftUI view updates. Root cause: cascade-deleted model objects accessed without `isDeleted` / `modelContext` guards.
- Added deletion guards across all view-update paths: `MessageBubble`, `ConversationRow`, `AttachmentView`, `ChatView`, and `filteredConversations`.

### Concurrency & Safety
- **Removed `UncheckedSendableBox`** — SwiftData `@Model` objects are no longer smuggled across actor boundaries. All `Task.detached` closures now capture UUIDs and re-fetch from `ModelContext` on MainActor.
- Added `@MainActor` to `SettingsManager` (required for `@Observable` classes read by SwiftUI).
- `SyntaxHighlighter` cache: replaced `nonisolated(unsafe)` dictionary with thread-safe `NSCache`.
- Video conversion tasks now tracked in `ConversationActivity` enum (`.convertingVideo`) — properly cancelled on conversation deletion.
- Transcription cancellation scoped per-conversation instead of cancelling all active transcriptions.

### OGG Audio Playback
- Fixed broken seek on OGG files — `AVAudioPlayer` cannot seek OGG reliably, so OGG files now use `AVPlayer` with `CMTime`-based seeking.
- Dual-backend `AudioPlayerView`: `AVPlayer` for OGG, `AVAudioPlayer` for everything else. Transparent to the user.

### Auto-Title Improvements
- Fixed auto-titler crash on force-unwrap of `autoTitleModel`.
- Auto-title no longer triggers after user manually stops streaming.
- Added `Task.checkCancellation()` in the streaming loop — cancelled title generation stops immediately.
- Added `isDeleted` guard before writing the generated title.

### Timestamp Seek
- Fixed timestamp click-to-seek not working after switching conversations. Seek requests pending at view creation time are now handled on `onAppear`, not only on `onChange`.

### LLM
- Anthropic API: default `anthropic-version: 2023-06-01` header added when not explicitly set.
- API key redaction: Bearer tokens, `sk-*`, and API key patterns are scrubbed from error messages shown to the user.

### Other Fixes
- `selectedConversationID` now picks the first remaining conversation after deletion (previously could point to the deleted one).
- `highlightCursor` clamped after batch-delete to prevent out-of-bounds crash.
- Export errors (JSON, PDF) now surface via the error banner instead of failing silently.
- Bulk ZIP export: temp file cleanup via `defer`, `process.waitUntilExit()` moved off MainActor.
- `SettingsStorage`: replaced `try!` / `print()` with safe decoding and `AppLogger.error()`.
- Video aspect ratio API returns `Optional` instead of magic 16:9 sentinel value.
- Conversation import now restores attachment metadata.

---

## v0.5.2 (2026-04-17)

### Python-Free Transcription (M15 Complete)
- Transcription now runs **in-process** via the native [metal-faster-whisper](https://github.com/vsevolod-oparin/metal-faster-whisper) framework (v0.2.2) — no more Python, no more Miniconda, no more subprocesses.
- **First launch is instant** — no ~60 MB Miniconda download, no `ct-transcriber-metal-env` environment setup. Just download a model and start transcribing.
- Native `MWModelManager` replaces the Python conversion scripts — models download directly from HuggingFace (pre-converted CTranslate2 repos).
- Removed ~970 lines of Python infrastructure: `PythonEnvironment.swift`, `EnvironmentSetupView.swift`, `transcribe.py`, `convert_model.py`, `setup_env.sh`.
- WebM files are decoded via `ffmpeg` (install via `brew install ffmpeg`); all other formats go through the framework directly.

### Signed & Notarized Distribution (M15d)
- App bundle and all embedded frameworks are now signed with **Developer ID Application** and **Hardened Runtime**.
- DMG is **notarized and stapled** — no more Gatekeeper warnings or `xattr -cr` workarounds on first launch.
- New `./scripts/create-dmg.sh --notarize` command handles codesign + notarytool submission + stapling in one step.
- Entitlements are minimal and explicit: network client (for HuggingFace + LLM APIs), user-selected file access.

### Internal
- Swift Package Manager binary targets for all three embedded frameworks (MetalWhisper, CTranslate2, OnnxRuntime) — no local paths, reproducible builds.
- Fixed several build-time issues: `Task` closure type-checker timeout in `ModelManager`, `AVAudioFile` rejecting video containers (fallback to `AVAssetReader`), `AVURLAsset` rejecting webm (fallback to `ffmpeg`).

---

## v0.5.1 (2026-03-20)

### Timestamp Click-to-Seek
- Click any timestamp line in a transcript to seek the audio/video player to that position.
- Works in both collapsed and expanded transcripts.
- Full cross-line text selection for copy-paste (NSTextView-based renderer).
- Timestamps rendered in monospaced secondary font — no underlines, pointing hand cursor on hover.
- Seek uses AudioPlaybackManager directly when player is active (works even when audio cell scrolled out).
- Frame-accurate seeking: `AVPlayer.seek` with `toleranceBefore: .zero, toleranceAfter: .zero`.

### Mini Player Fix
- Play/pause toggle now works correctly. Previously the mini player could only pause — now it can resume via new `resumeCallback` on AudioPlaybackManager.

### macOS Services Integration
- Right-click audio/video files in Finder → Services → "Transcribe with CT Transcriber".
- No separate extension target — uses macOS Services via Info.plist `NSServices` entry.
- Auto-cleanup: service registration lives in app bundle, removed when app is deleted.

### NSCache Migration
- Video aspect ratio cache: `[String: CGFloat]` dictionary → `NSCache<NSString, NSNumber>`. Auto-evicts under memory pressure.
- Video thumbnail cache: per-cell `@State` regeneration → shared `NSCache<NSString, NSImage>`. Thumbnails persist across cell reuse — no re-generation on scroll-back.

### Timer Modernization
- AudioPlayerView: replaced `Timer.scheduledTimer` with `.onReceive(Timer.publish)`. No manual `startTimer()`/`stopTimer()`, no `MainActor.assumeIsolated` workaround, no leak risk.

### Video Playback Fix
- Fixed simultaneous video playback bug: native `AVPlayerView` floating controls could start playback without notifying `AudioPlaybackManager`. Now detected via periodic observer rate monitoring — our `startPlayback()`/`pausePlayback()` syncs with native control state.

### Stress Test
- Validated NSTableView at 1000+ and 5000 messages. Per-message hash: 0.004ms, sort: 0.080ms, markdown parse: 0.028ms. All sub-millisecond in hot paths.
- `isDynamicContentLocked` scroll optimization attempted and rejected — placeholder cells caused visible flashing without meaningful performance gain. Height caching is sufficient.

### Rejected Optimizations
- `isDynamicContentLocked` (scroll placeholders) — visual flashing worse than any gain.
- Visibility-based audio pause — bad UX for podcasts (rejected in v0.5.0).

---

## v0.5.0 (2026-03-20)

### Syntax Highlighting
- Code blocks in assistant messages now render with colored syntax — keywords, types, strings, numbers, comments, and decorators.
- Zero external dependencies: regex-based highlighter with cached results. Supports Swift, Python, JavaScript/TypeScript, C/C++, Rust, Go, Java, Ruby, and shell.

### Architecture Improvements
- **`@Query` migration** — replaced ~20 manual `refreshConversations()` calls with SwiftData's `@Query` for automatic, incremental conversation list updates.
- **Swift strict concurrency** — enabled `SWIFT_STRICT_CONCURRENCY = complete`. Fixed ~40 warnings across the codebase. Zero concurrency warnings remaining.

### Drag & Drop Export
- Drag any attachment (audio, video, image, text) out of the app directly to Finder, Desktop, or other apps.

---

## v0.4.0 (2026-03-20)

### Markdown Rendering
- Assistant messages now render with full markdown formatting: **bold**, *italic*, ~~strikethrough~~, `inline code`, [links], headers, lists, tables, and fenced code blocks with copy buttons.
- Per-conversation toggle (toolbar button) to switch between rendered markdown and raw text.
- Nested list support with visual indentation. `<br>` tag handling in table cells.

### Content Export
- **Export as PDF** (Cmd+E) — formatted document with inline markdown, real table grids (NSTextTable), code blocks, role headers, and timestamps.
- **Export as JSON** (Cmd+Shift+E) — machine-readable format with ISO 8601 dates.
- **Export as Markdown** — human-readable with role headers and attachment badges.
- **Export All Conversations** — bulk ZIP archive of all conversations as JSON.
- **Export as PDF** also available from conversation right-click menu.

### Content Import
- **Import Conversation** (Cmd+Shift+I) — import a previously exported JSON file as a new conversation.

### Downloadable Media
- Right-click any attachment → **Save As...** or **Reveal in Finder**.
- Right-click transcription → **Export as Text** (timestamps stripped), **Export as Markdown**, or **Export as SRT** (subtitles).

---

## v0.3.1 (2026-03-20)

### Performance Fix
- **Typing freeze eliminated** — `PythonEnvironment.check()` was spawning a Python subprocess (1.1–1.8 seconds) on every transcription start, blocking the main thread. Now cached after first check.

### Schema Versioning
- Wired up `SchemaVersioning.swift` to the ModelContainer with `CTTranscriberMigrationPlan`. Future schema changes will have proper migration paths. 8 unit tests added.

---

## v0.3.0 (2026-03-19)

### FSM State Management
- Added `MessageLifecycle` enum (7 states) — replaces fragile string-prefix state detection with typed state (`.streaming`, `.transcribing`, `.errorLLM`, `.errorTranscription`, `.cancelled`, etc.).
- Added `ConversationActivity` enum — replaces scattered boolean flags with per-conversation activity tracking.
- Per-conversation transcription progress — progress bar now shows only on the conversation being transcribed.

### Anti-Pattern Audit
- 20 findings across the codebase (4 HIGH, 8 MEDIUM, 8 LOW). 14 fixed.
- Rewrote CLAUDE.md anti-patterns section for Swift/SwiftUI/SwiftData.
- Added investigation discipline protocol for crash analysis.

### Crash Fixes
- Fixed 3 crashes caused by SwiftData cascade deletion during NSAlert dismissal. Root cause: `isDeleted` is unreliable for cascade-deleted relationship targets — must also check `modelContext != nil`.
- `deleteConversation` restructured to collect data before deletion and move file I/O off MainActor.
- `ForEach(message.attachments)` now filters deleted objects.
- `sortedMessages(for:)` guards against deleted conversations.

### Video Sizing
- Fixed WebM/MKV video bubble truncation — aspect ratio discovery chain: AVAsset can't read WebM, so real ratio is computed from converted MP4 and written back to static cache.
- Portrait videos now get `maxH = 450` (up from 300) for better visibility.
- Video aspect ratios precomputed synchronously on conversation load — eliminates initial truncation flash.
- Replaced `.fixedSize(horizontal:)` with explicit `.frame(width:)` — fixes `sizeThatFits` returning incorrect heights.
- Changed `AVPlayerView.controlsStyle` from `.inline` to `.floating` — controls overlay instead of adding height.

### Concurrency & Performance
- Transcription stream processing moved off MainActor (`Task.detached` with throttled UI updates).
- `@MainActor` added to `AudioPlaybackManager` and `ModelManager`.
- `videoAspectRatioCache` writes synchronized to MainActor.
- `pendingTranscriptions` stores UUIDs instead of SwiftData model references.
- `Task.detached` in `autoNameConversation` replaced with `Task` (inherits MainActor).
- `attachFile` passes conversation ID across actor boundary instead of model object.
- BackgroundTask objects properly cancelled when conversation deleted.

### File Organization
- Split `ChatView.swift` (2055 lines) into 6 files: `ChatTableView.swift`, `MessageBubble.swift`, `MediaPlayerViews.swift`, `AttachmentView.swift`, `ChatInputBar.swift`, and trimmed `ChatView.swift`.

---

## v0.2.0 (2026-03-19)

Initial distributed release. All core features complete:
- Multi-provider LLM chat (OpenAI, Anthropic, DeepSeek, Qwen, Z.ai)
- Audio/video transcription via faster-whisper with Metal GPU acceleration
- Auto-managed Python/conda environment with zero-setup UX
- Model download and conversion management
- Background task manager
- macOS integration (Finder, Dock drop, drag-and-drop)
- Sidebar with multi-select, font scaling, search
- Audio/video player with seek bar, mini-player, WebM conversion
- Unsigned DMG distribution with uninstaller
