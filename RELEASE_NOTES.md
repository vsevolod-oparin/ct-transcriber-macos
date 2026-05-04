# CT Transcriber 0.5.4 Release Notes

## Data Consolidation

All app data now lives in a single directory: `~/Library/Application Support/CTTranscriber/`. This makes it easy to find, back up, and cleanly uninstall.

```
~/Library/Application Support/CTTranscriber/
├── settings.json        ← Settings
├── ct-transcriber.log   ← Logs
├── data/                ← SwiftData database
├── files/               ← Attachments
└── models/              ← Whisper models
```

On first launch, existing data is automatically migrated from the old scattered locations (XDG config, Caches, root Application Support).

## Code Quality

- **Round 3 review**: 20 findings audited, 15 confirmed already fixed from prior rounds, 5 new fixes applied
- Removed 6 duplicate time formatting functions — consolidated into `TimeFormatting` utility
- Removed 2 duplicate view search functions — consolidated into `ViewUtils` utility
- Fixed `safeName` in bulk export to strip `..`, backslashes, and control characters
- Fixed unsupported video files showing "Converting..." instead of "Playback not supported"

## Full Changelog (0.5.1 → 0.5.4)

### Bug Fixes
- Fixed whisper model download not persisting status when navigating away from settings
- Fixed search cache not invalidating when query text changed
- Fixed video conversion continuing after conversation deletion
- Fixed `highlightCursor` out-of-bounds crash after deleting highlighted conversations
- Fixed export functions failing silently — now show error alerts
- Fixed `findMessage` using O(C×M) scan when conversation ID was available
- Fixed `ModelManager.cancelDownload` race condition
- Fixed temp ZIP/ditto cleanup on cancellation and error
- Fixed Anthropic API calls missing `anthropic-version` header
- Fixed API keys leaking into error logs via `LLMError.redactSensitiveInfo()`
- Fixed `autoTitleModel` force-unwrap crash when provider has no model set
- Fixed `attachFile` retain cycle from `[self]` capture in MainActor.run
- Fixed auto-title running after user manually stopped streaming
- Fixed `UnsupportedVideoView` showing false "Converting..." label
- Fixed video converter and ditto processes not terminating on task cancellation
- Fixed `AppLogger.logFileURL` and `SettingsStorage` force unwraps with fallbacks
- Fixed conversation deletion not updating `selectedConversationID`
- Fixed `saveAttachment` overwriting existing files without warning
- Fixed `ConversationExporter.importJSON` restoring attachment metadata

### Improvements
- All app data consolidated under `~/Library/Application Support/CTTranscriber/`
- Automatic one-time migration from old data locations
- `@MainActor` annotation added to `SettingsManager`
- Duplicate code extracted into shared `TimeFormatting` and `ViewUtils` utilities
- `AppUninstaller` cleans up all consolidated + legacy paths
- SRT timestamps now type-safe (parsed `TimeInterval` instead of raw strings)
- Export/import handles attachment metadata properly
