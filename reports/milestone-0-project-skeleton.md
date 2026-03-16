# Milestone 0: Project Skeleton & Build System

**Date:** 2026-03-16
**Status:** Complete

---

## What Was Done

### Xcode Project Setup
- Used `xcodegen` (v2.45.3) to generate `CTTranscriber.xcodeproj` from `project.yml`
- Deployment target: macOS 14.0+ (Sonoma) — required for SwiftData
- Swift 5.10, Bundle ID: `com.branch.ct-transcriber`, Product name: "CT Transcriber"
- No signing team configured (unsigned distribution per RFC)

### Directory Structure Created

```
CTTranscriber/
  App/CTTranscriberApp.swift        — @main entry, WindowGroup + Settings scene, SwiftData container
  Models/Conversation.swift         — @Model: id, title, createdAt, updatedAt, messages relationship
  Models/Message.swift              — @Model: id, role (enum), content, timestamp, audioFilePath?
  Views/ContentView.swift           — NavigationSplitView shell with sidebar + empty state
  ViewModels/                       — Empty, ready for M1
  Services/                         — Empty, ready for M4/M5
  Resources/                        — Empty, ready for M10
  Python/                           — Empty, ready for M5
```

### Key Decisions
- **xcodegen over manual .pbxproj**: `project.yml` is human-readable and diffable; the generated `.xcodeproj` can be regenerated anytime. This avoids merge conflicts on the binary pbxproj format.
- **SwiftData models included early**: `Conversation` and `Message` models are defined in M0 even though persistence is M2's scope. This was needed because `CTTranscriberApp` declares `.modelContainer(for: Conversation.self)` and the app won't compile without the model types. The models are minimal stubs — M2 will flesh them out.
- **NavigationSplitView in ContentView**: Chose the two-column variant (sidebar + detail) matching the RFC's "hidable left panel" requirement. The three-column variant was unnecessary.

### Build & Launch Verification
- `xcodebuild -scheme CTTranscriber -configuration Debug build` → **BUILD SUCCEEDED**
- App launched via `open`, confirmed running process, shows window with sidebar and "No Conversation Selected" empty state
- `.gitignore` updated with `DerivedData/` and `**/.DS_Store`

---

## Test Criteria Results

| Criteria | Result |
|----------|--------|
| `Cmd+R` in Xcode builds without errors | PASS (verified via xcodebuild) |
| App shows window with title "CT Transcriber" | PASS |

---

## Files Created/Modified

- **Created:** `project.yml`, `CTTranscriber/App/CTTranscriberApp.swift`, `CTTranscriber/Models/Conversation.swift`, `CTTranscriber/Models/Message.swift`, `CTTranscriber/Views/ContentView.swift`, `.gitkeep` files for empty dirs
- **Modified:** `.gitignore` (added DerivedData/, .DS_Store)
- **Generated:** `CTTranscriber.xcodeproj/` (via xcodegen)
