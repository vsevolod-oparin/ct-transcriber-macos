# Feature: Timer Migration & Video Playback Fixes

**Date:** 2026-03-20
**Version:** 0.5.0+

---

## Timer Migration: Timer.scheduledTimer → .onReceive(Timer.publish)

### What Changed

Replaced `Timer.scheduledTimer` with closure in `AudioPlayerView` with SwiftUI's `.onReceive(Timer.publish)` modifier.

### Before

```swift
@State private var timer: Timer?

private func startTimer() {
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        MainActor.assumeIsolated {
            // update currentTime, detect end-of-playback
        }
    }
}

private func stopTimer() {
    timer?.invalidate()
    timer = nil
}
```

- Manual `startTimer()` / `stopTimer()` calls in `startPlayback()`, `pausePlayback()`, `cleanup()`, `onResume`, `onSeek`
- `MainActor.assumeIsolated` needed because Timer closure runs outside SwiftUI view body
- Risk of timer leak if `invalidate()` is missed in any code path

### After

```swift
.onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
    guard isPlaying, let player, !isDragging else { return }
    currentTime = player.currentTime
    AudioPlaybackManager.shared.currentTime = currentTime
    if !player.isPlaying {
        isPlaying = false
        persistPosition()
        AudioPlaybackManager.shared.didFinishPlaying(storedName: attachment.storedName)
    }
}
```

- No manual start/stop — timer fires continuously, handler early-returns when not playing
- No `MainActor.assumeIsolated` — `.onReceive` runs in the view body context
- No leak risk — SwiftUI manages the timer subscription lifecycle
- Removed: `@State private var timer: Timer?`, `startTimer()`, `stopTimer()`
- Removed: all `startTimer()` calls from `startPlayback()`, `onResume`, `onSeek` callbacks

### What Was NOT Changed

- `AudioPlaybackManager.miniPlayerTimer` — this is in a singleton service, not a SwiftUI view. `.onReceive` doesn't apply. Stays as `Timer.scheduledTimer`.
- `VideoPlayerView` — uses `AVPlayer.addPeriodicTimeObserver` (AVFoundation's own observer), not a Timer. No change needed.

---

## Bug Fix: Simultaneous Video Playback

### Symptom

Two videos in the same conversation could play simultaneously when using the native AVPlayerView floating controls (hover play button). The mini player bar didn't appear, and neither video paused the other.

### Root Cause

`AVPlayerView` with `.controlsStyle = .floating` has built-in transport controls. When the user clicks the native play button, `AVPlayer.play()` is called directly by AppKit — our `startPlayback()` method is never invoked. `AudioPlaybackManager` never knows about the playback and never pauses the other video.

### Fix

The existing `addPeriodicTimeObserver` callback (fires every 0.1s on main queue) now detects rate changes from the native controls:

```swift
timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
    MainActor.assumeIsolated {
        // Detect playback started by native AVPlayerView controls
        if player.rate > 0 && !isPlaying {
            startPlayback()  // registers with AudioPlaybackManager, pauses other media
        } else if player.rate == 0 && isPlaying {
            pausePlayback()  // notifies AudioPlaybackManager
        }
        // ... existing time update and end-of-playback detection
    }
}
```

- `player.rate > 0 && !isPlaying` → native controls started playback → our `startPlayback()` registers with `AudioPlaybackManager` which pauses any other playing media
- `player.rate == 0 && isPlaying` → native controls paused → our `pausePlayback()` updates `AudioPlaybackManager`

This syncs the native AVPlayerView state with our playback management, ensuring only one media plays at a time regardless of how playback was initiated.

---

## Files Modified

| File | Changes |
|------|---------|
| `MediaPlayerViews.swift` | AudioPlayerView: replaced Timer with `.onReceive`; removed `startTimer()`/`stopTimer()`/`@State timer`. VideoPlayerView: added rate change detection in periodic observer to sync native controls with AudioPlaybackManager. |
