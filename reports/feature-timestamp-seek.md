# Feature: Line-Level Timestamp Click-to-Seek

**Date:** 2026-03-20
**Version:** 0.5.0+

---

## Summary

Click any timestamp line in a transcript to seek the audio/video player to that position. Works in both collapsed and expanded transcripts, with full cross-line text selection for copy-paste.

## Implementation

### TranscriptTextView (NSViewRepresentable)

Replaced the default `MarkdownContentView` / plain `Text` rendering for transcript messages with a custom `TranscriptTextView` backed by `NSTextView`.

**Why NSTextView, not SwiftUI Text:**
- SwiftUI `ForEach` with individual `Text` views doesn't support cross-line text selection
- A single `Text(content)` can't have per-line click targets
- NSTextView provides native text selection + programmatic click handling

**Architecture:**
- `TranscriptTextView: NSViewRepresentable` — renders transcript with NSAttributedString
- `TranscriptNSTextView: NSTextView` subclass — overrides `mouseDown` for click detection
- `Coordinator` — maps click position to source line number, looks up timestamp, fires seek

### Click Detection

Initial approach used NSTextView link attributes (`NSAttributedString.Key.link` with `seek://time` URLs). This failed because NSTextView's `clickedOnLink:at:charIndex` returns incorrect character indices when embedded in NSHostingView inside NSTableView — the coordinate transformations between layers cause an offset.

**Final approach — line-number detection:**
1. `mouseDown` receives click point in NSTextView coordinates
2. `layoutManager.characterIndex(for:in:)` converts point to character index
3. Count newlines in the text prefix up to that character → source line number
4. Look up `lineTimestamps[lineNumber]` (pre-parsed dictionary of line → TimeInterval)
5. Fire seek via AudioPlaybackManager or seekRequest binding

This is reliable because the line-to-timestamp mapping is by counting `\n` characters, not by link hit testing.

### Seek Dispatch

Two paths depending on whether the audio player is already active:

1. **AudioPlaybackManager has the player** (common — audio was played before, cell may be off-screen): seeks directly via `mgr.seek(to:)` and resumes if paused. Works even when the AudioPlayerView cell is destroyed by NSTableView reuse because the manager keeps `activePlayer` alive.

2. **First time playing** (manager doesn't have this audio): falls back to `seekRequest` binding, which the AudioPlayerView picks up via `onChange(of: seekRequest?.id)`.

### Mini Player Fix

The mini player's `togglePlayPause()` previously only called `pauseCallback()` — it couldn't resume. Added `resumeCallback` to `AudioPlaybackManager`, passed from both `AudioPlayerView` and `VideoPlayerView` during `startPlayback()`.

### Accurate Seeking

`AVPlayer.seek(to:)` without tolerance defaults to nearest-keyframe seeking, which can be 1-2 seconds off. Fixed by using `seek(to:toleranceBefore:toleranceAfter:)` with `.zero` tolerance for frame-accurate positioning. Applied to both the `onSeek` callback and the `seekRequest` onChange handler.

## Rendering

### Attributed String

- Timestamp portions (`[0:45 → 0:50]`) — monospaced font at 90% size, secondary label color
- Text portions — body font, primary label color
- Non-timestamp lines (header "**Transcription** (ru, 9.5)") — body font, primary color
- No underlines, no link attributes — visual distinction is through font only
- Pointing hand cursor over entire transcript area

### Integration Points

| Condition | Rendering |
|-----------|-----------|
| Transcript + collapsed (isLong && !isExpanded) | TranscriptTextView with collapsedPreview content |
| Transcript + expanded | TranscriptTextView with full content |
| Transcript + large (>5000 chars) | TranscriptTextView (overrides largeTextThreshold) |
| Non-transcript assistant message | MarkdownContentView |
| User message | Plain Text |
| Streaming | Plain Text + spinner |

Detection: `info.hasTimestamps && !isStreamingThis && findAudioAttachment() != nil`

## Bugs Found and Fixed During Development

1. **NSTextView link charIndex offset** — link-based click detection returned wrong character indices in NSHostingView embedding. Fixed by replacing with line-number detection via `mouseDown` override.

2. **Mini player couldn't resume** — `togglePlayPause()` only had `pauseCallback`, no `resumeCallback`. Added resume callback to both audio and video players.

3. **Keyframe-snapping seeks** — `AVPlayer.seek(to:)` defaults to approximate seeking. Fixed with `toleranceBefore: .zero, toleranceAfter: .zero` for exact positioning.

4. **Collapsed transcripts not clickable** — collapsed preview rendered as plain `Text`. Fixed by routing collapsed transcripts through `TranscriptTextView` when timestamps are detected.

5. **Large transcripts skipped** — transcripts >5000 chars went to `LargeTextView` (plain NSTextView, no click handling). Fixed by checking `hasTimestamps` before the `largeTextThreshold` check.

## Files Modified

| File | Changes |
|------|---------|
| `MessageBubble.swift` | Added `TranscriptTextView`, `TranscriptNSTextView`; updated `bubbleContent` rendering order |
| `AudioPlaybackManager.swift` | Added `resumeCallback`; fixed `togglePlayPause` to actually toggle; `seek(to:)` unchanged |
| `MediaPlayerViews.swift` | Added `onResume` callback in both AudioPlayerView and VideoPlayerView; zero-tolerance `AVPlayer.seek` |
