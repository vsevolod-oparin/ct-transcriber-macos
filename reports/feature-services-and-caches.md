# Feature: macOS Services Integration & NSCache Migration

**Date:** 2026-03-20
**Version:** 0.5.0+

---

## macOS Services Integration

### What

Right-click any audio/video file in Finder → Services → "Transcribe with CT Transcriber". The app activates, creates a new conversation, and auto-transcribes the file.

### Implementation

Used the macOS **Services** mechanism instead of a Share Extension. Services are simpler (no separate target, no App Groups, no entitlements) and achieve the same right-click UX.

**Info.plist:**
- Added `NSServices` array with a single service definition
- `NSMenuItem.default` = "Transcribe with CT Transcriber"
- `NSMessage` = `openFilesFromService` (the Obj-C selector called by macOS)
- `NSPortName` = "CT Transcriber" (must match the app name)
- `NSSendFileTypes` = all supported audio/video UTTypes (public.audio, public.movie, public.video, public.mpeg-4, org.webmproject.webm, org.matroska.mkv, public.mp3, com.apple.m4a-audio, etc.)

**AppDelegate:**
- `applicationDidFinishLaunching` registers `self` as `NSApp.servicesProvider`
- `openFilesFromService(_:userData:error:)` reads file URLs from the pasteboard, appends to `pendingOpenURLs`, activates the app window
- Method is `@MainActor @objc` for strict concurrency compliance

### Cleanup on Uninstall

No extra cleanup needed. The Services entry lives in `Info.plist` inside the app bundle. When the app is deleted (by the uninstaller or manually), macOS removes the service from the Services registry automatically on next `pbs -update` cycle or reboot.

Verified: the existing `AppUninstaller.run()` deletes the app bundle (`appPath`), which removes the Info.plist containing the service registration.

### Why Services, Not Share Extension

| Aspect | Share Extension | Services |
|--------|----------------|----------|
| Separate Xcode target | Required | Not needed |
| App Groups / IPC | Required for communication | Not needed — same process |
| Info.plist only | No | Yes |
| Entitlements | Required | Not needed |
| Cleanup on delete | Manual unregister | Automatic |
| UX location | Share menu | Services submenu |
| Complexity | High (new target, bundle, provisioning) | Low (~30 lines of code) |

---

## NSCache Migration for Video Data

### What

Replaced in-memory dictionaries with `NSCache` for video aspect ratios and thumbnails. `NSCache` auto-evicts under memory pressure and is thread-safe.

### Before

| Cache | Type | Eviction | Thread Safety |
|-------|------|----------|---------------|
| Aspect ratios | `static var [String: CGFloat]` | Never — grows unbounded | `nonisolated(unsafe)` |
| Thumbnails | `@State` per cell | Per-cell — regenerated on every scroll-in | SwiftUI managed |

### After

| Cache | Type | Eviction | Thread Safety |
|-------|------|----------|---------------|
| Aspect ratios | `NSCache<NSString, NSNumber>` | Auto under memory pressure | Built-in (NSCache is thread-safe) |
| Thumbnails | `NSCache<NSString, NSImage>` | Auto under memory pressure | Built-in |

### Changes

**ChatTableView.Coordinator:**
- `videoAspectRatioCache: [String: CGFloat]` → `aspectRatioCache: NSCache<NSString, NSNumber>`
- `videoAspectRatio(url:)` reads from NSCache, returns 16:9 default on miss
- `setVideoAspectRatio(_:for:)` writes to NSCache
- `precomputeVideoAspectRatio(url:)` writes to NSCache via `DispatchQueue.main.async`
- Added `thumbnailCache: NSCache<NSString, NSImage>` (shared static)
- Added `videoThumbnail(for:)` and `setVideoThumbnail(_:for:)` accessors

**MediaPlayerViews.swift (AudioPlayerView):**
- Thumbnail loading checks `ChatTableView.Coordinator.videoThumbnail(for:)` first
- On cache miss, generates thumbnail in `Task.detached` and stores via `setVideoThumbnail`
- On cache hit, assigns directly to `@State videoThumbnail` — no background work

### Performance Impact

- **Scrolling with videos:** thumbnails load instantly from cache on scroll-back (was: regenerated from disk every time)
- **Memory pressure:** both caches auto-evict, preventing unbounded growth for conversations with many videos
- **First load:** unchanged (still generates thumbnail in background Task)

---

## Files Modified

| File | Changes |
|------|---------|
| `CTTranscriberApp.swift` | `applicationDidFinishLaunching` registers services provider; `openFilesFromService` handles pasteboard |
| `Info.plist` | Added `NSServices` array for "Transcribe with CT Transcriber" |
| `ChatTableView.swift` | Replaced `videoAspectRatioCache` dict with `NSCache`; added `thumbnailCache` with accessors |
| `MediaPlayerViews.swift` | Thumbnail loading checks shared cache before generating |
