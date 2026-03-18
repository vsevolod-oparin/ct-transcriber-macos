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

### App Icon

Custom icon generated from `waveform.circle.fill` SF Symbol:
- Light blue gradient background with blue circle + white waveform
- Apple HIG compliant: 10% transparent margin, ~80% content area
- All required macOS sizes (16–1024px) in `Assets.xcassets/AppIcon.appiconset`
- Drop shadow for depth

### Per-Conversation LLM Streaming

Fully isolated per-conversation streaming:
- `streamingTasks: [UUID: Task]` — each conversation gets its own Task
- `streamingConversationIDs: Set<UUID>` — tracks which conversations are streaming
- `isStreamingCurrentConversation` — only disables controls for the active conversation
- Local `accumulatedText` per Task — no cross-talk between conversations
- Switch conversations freely while LLM is streaming

### Ollama Support

Pre-configured local LLM provider:
- Base URL: `http://localhost:11434`
- OpenAI-compatible API
- Default model: llama3.2, fallbacks: llama3.1, mistral, gemma2, qwen2.5
- Model picker fetches available models from Ollama API

### Main-Thread Blocking Audit

Comprehensive audit identified and fixed 3 critical issues:
1. **AVAsset.tracks() in heightOfRow** — moved to background pre-computation on file attach
2. **AVAsset.tracks() in VideoPlayerView.loadVideo** — replaced with async `loadTracks()` API
3. **NSImage(contentsOf:) in ImageAttachmentView** — moved to `Task.detached`

### Documentation

- **README.md** — features, installation, architecture, keyboard shortcuts
- **LICENSE** — MIT License, Copyright 2026 Vsevolod Oparin
- **About window** — author (Vsevolod Oparin), GitHub link, credits

### Already Complete (from earlier milestones)
- Dark mode via `.preferredColorScheme`
- First-launch onboarding (EnvironmentSetupView)
- Error states with `[LLM]`/`[Transcription]` prefixes
- Font scaling throughout

---

## Files Created/Modified

- **Modified:** `CTTranscriberApp.swift` — menu commands, About view, Cmd+O open panel, per-conversation streaming
- **Modified:** `ChatViewModel.swift` — `streamingTasks`, `streamingConversationIDs`, isolated streaming, blocking fixes
- **Modified:** `ChatView.swift` — `isStreamingCurrentConversation`, async image/video loading, pre-computed aspect ratios
- **Modified:** `ContentView.swift` — receives `createNewConversation` notification
- **Created:** `scripts/create-dmg.sh` — DMG builder script
- **Created:** `README.md` — project documentation
- **Created:** `LICENSE` — MIT License
- **Created:** `Assets.xcassets/AppIcon.appiconset/` — app icon at all required sizes
- **Modified:** `default-settings.json` — Ollama provider config
- **Modified:** `Info.plist` — CFBundleIconName, CFBundleIconFile
