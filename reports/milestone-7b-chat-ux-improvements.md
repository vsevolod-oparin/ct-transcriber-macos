# Milestone 7b: Chat UX Improvements (partial)

**Date:** 2026-03-17
**Status:** Partially Complete (performance optimization deferred)

---

## What Was Done

### Collapsible Bubbles
- Messages with more than 15 lines auto-collapse (configurable via `collapseThreshold`)
- Collapsed view shows first 5 lines + "..." + "Show more (N lines)" toggle
- Click to expand/collapse with animation
- Streaming messages are never collapsed (always expanded during streaming)

### Bubble Copy
- **Hover**: copy button (doc.on.doc icon) appears top-right on hover
- **Context menu** (right-click):
  - "Copy" — copies full message text
  - "Copy without timestamps" — strips `[0:00 → 0:03]` prefixes (shown only for transcription results)
- **Retry** option in context menu for failed messages

### Audio/Video Player
- Audio and video attachments show a play/pause button (play.circle.fill / pause.circle.fill)
- Uses `AVAudioPlayer` for playback from the stored file
- Play/pause toggles inline — no separate window
- Player stops on view disappear (switching conversations)

### Message Status & Retry
- **Error detection**: messages starting with "Transcription failed" or "Transcription cancelled" are marked as errors
- **Visual indicator**: error messages get a red-tinted background (`.red.opacity(0.15)`)
- **Status row**: shows error icon + timestamp + "Retry" button
- **Context menu**: "Retry" option for failed messages
- **Retry logic** (`ChatViewModel.retryMessage`):
  - For assistant/system messages: deletes the failed message, re-triggers LLM response
  - For user messages: deletes the message + any following response, re-creates and re-sends

### LLM API Key Test
- "Test Connection" button in Settings → LLM → Authentication section
- Sends a minimal request ("Hi", max_tokens=1) using the configured provider
- Shows result inline:
  - Spinner while testing
  - Green "Connected" checkmark on success
  - Red error message on failure (auth error, insufficient funds, network error, etc.)
- Disabled when no API key is entered

---

## Files Created/Modified

- **Modified:** `Views/ChatView.swift` (complete rewrite: collapsible bubbles, copy on hover + context menu, audio player, error status + retry, transcription timestamp stripping), `ViewModels/ChatViewModel.swift` (added `retryMessage`), `Views/SettingsView.swift` (added Test Connection button + logic)
