# Milestone 10: Polish & Distribution

**Date:** 2026-03-18
**Status:** Complete

---

## What Was Done

### Menu Bar

Proper macOS menu bar with:
- **File → New Conversation** (Cmd+N) — creates new conversation via NotificationCenter
- **File → Open Audio/Video...** (Cmd+O) — opens NSOpenPanel for audio/video files (mp3, m4a, wav, flac, mp4, mov, webm, mkv)
- **View → Increase/Decrease/Reset Font Size** (Cmd+Plus/Minus/0) — font scaling
- **CT Transcriber → About CT Transcriber** — opens About window
- **CT Transcriber → Settings...** (Cmd+,) — automatic from SwiftUI Settings scene
- "New Window" replaced with "New Conversation" (single-window app)

### About Window

Sheet with:
- App icon (waveform.circle.fill system symbol)
- App name "CT Transcriber"
- Version + build number (from Info.plist)
- Description
- Credits (CTranslate2, faster-whisper, Whisper)
- OK button (Enter) / Escape to close

### Cmd+O (Open Audio/Video)

- NSOpenPanel with audio + video content types including WebM/MKV
- Multiple selection supported
- Files routed through `appDelegate.pendingOpenURLs` → same flow as Finder "Open With"

### DMG Creation Script

`scripts/create-dmg.sh`:
- Builds Release configuration via xcodebuild
- Creates staging directory with app + Applications symlink + README.txt
- README includes installation, Gatekeeper bypass, and requirements
- Creates UDZO-compressed DMG via hdiutil
- Output: `dist/CTTranscriber-<version>.dmg`
- Supports `--skip-build` flag for pre-built app

### Already Complete (from earlier milestones)
- Dark mode via `.preferredColorScheme`
- First-launch onboarding (EnvironmentSetupView)
- Error states with `[LLM]`/`[Transcription]` prefixes
- Font scaling throughout

---

## Files Created/Modified

- **Modified:** `CTTranscriberApp.swift` — menu commands, About view, Cmd+O open panel, NotificationCenter
- **Modified:** `ContentView.swift` — receives `createNewConversation` notification
- **Created:** `scripts/create-dmg.sh` — DMG builder script
