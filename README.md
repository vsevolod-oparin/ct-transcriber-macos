# CT Transcriber

A native macOS app for audio and video transcription with LLM chat capabilities, powered by the CTranslate2 Metal backend (via the bundled [metal-faster-whisper](https://github.com/vsevolod-oparin/metal-faster-whisper) framework) on Apple Silicon.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)
![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon-orange.svg)

## Features

### Transcription
- **Whisper models** via the native MetalWhisper framework (in-process ObjC/C++, no Python)
- **Multiple models**: Large V3 Turbo, Large V3, Base (configurable)
- **Audio formats**: MP3, M4A, WAV, FLAC, AIFF, CAF, OGG, Opus
- **Video formats**: MP4, MOV, AVI, WebM, MKV (audio extracted automatically via ffmpeg fallback for WebM)
- **Timestamps**: optional `[start → end]` per segment with click-to-seek
- **VAD filter**: Silero VAD via ONNX Runtime, bundled in-framework
- **Background queue**: configurable parallel transcriptions (1–4)

### LLM Chat
- **Multi-provider**: Z.ai, OpenAI, Anthropic, DeepSeek, Qwen, Ollama (local)
- **Streaming**: real-time token display with stop button
- **Per-conversation streaming**: multiple simultaneous LLM requests across conversations
- **Auto-naming**: LLM generates conversation title (language-aware)
- **Error handling**: `[LLM]` / `[Transcription]` prefixed errors with smart retry

### Media Player
- **Audio**: seek bar, duration, persistent playback position
- **Video**: native AVPlayerView with inline controls, aspect-ratio aware
- **Floating mini-player**: control playback when player scrolls out of view
- **Single-audio enforcement**: only one plays at a time
- **Transcript sync**: right-click transcript → "Play from [timestamp]"

### UI
- **NSTableView chat**: smooth scroll, expand/collapse, height caching (TelegramSwift-inspired)
- **Font scaling**: Cmd+/Cmd-/Cmd+0, 70%–200% range, persisted
- **Sidebar**: multi-select (Shift/Cmd+Click/Arrow), Backspace delete, Tab focus toggle
- **Drag-and-drop**: into chat area, input bar, empty state, Dock icon
- **Finder integration**: "Open With" for audio/video files
- **Dark mode**: native SwiftUI theme support

## Requirements

- **macOS 14.0+** (Sonoma)
- **Apple Silicon** (M1/M2/M3/M4)
- Internet connection to download models and for LLM features
- 1.6–3.1 GB disk space for Whisper models
- `ffmpeg` in PATH is optional — only needed to transcribe WebM files (`brew install ffmpeg`)

## Installation

### From DMG

1. Download the latest `.dmg` from [Releases](https://github.com/vsevolod-oparin/ct-transcriber-macos/releases)
2. Drag **CT Transcriber** to Applications
3. On first launch: right-click → Open (or run `xattr -cr /Applications/CT\ Transcriber.app` to bypass Gatekeeper if the build is unsigned)
4. Open Settings → Transcription → Manage Models and download a model — the app is ready to transcribe immediately (no environment setup)

### Build from Source

```bash
# Prerequisites: Xcode 16.2+, xcodegen
brew install xcodegen

# Clone and build
git clone https://github.com/vsevolod-oparin/ct-transcriber-macos.git
cd ct-transcriber-macos
xcodegen generate
xcodebuild -scheme CTTranscriber -destination 'platform=macOS' build

# Or create a DMG
./scripts/create-dmg.sh
```

## First Launch

Transcription runs in-process via the bundled MetalWhisper framework — no Python, conda, or background installers.

1. Go to **Settings → Transcription → Manage Models** and download a Whisper model (Turbo recommended for speed, Large V3 for best accuracy)
2. Go to **Settings → LLM** and configure an API key for your preferred provider
3. Create a conversation and start chatting or attach audio/video files

## Supported LLM Providers

| Provider | Type | Default Model |
|----------|------|---------------|
| Z.ai Coding | OpenAI Compatible | glm-4.7 |
| Z.ai | OpenAI Compatible | glm-4.7 |
| OpenAI | OpenAI Compatible | gpt-4o-mini |
| Anthropic | Anthropic | claude-sonnet-4-20250514 |
| DeepSeek | OpenAI Compatible | deepseek-chat |
| Qwen | OpenAI Compatible | qwen-plus |
| Ollama (Local) | OpenAI Compatible | llama3.2 |

Add custom providers via Settings → LLM → "+" button.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+N | New conversation |
| Cmd+O | Open audio/video file |
| Cmd+, | Settings |
| Cmd+Plus | Increase font size |
| Cmd+Minus | Decrease font size |
| Cmd+0 | Reset font size |
| Cmd+Up | Scroll to top of chat |
| Cmd+Down | Scroll to bottom of chat |
| Tab | Toggle focus: sidebar ↔ input |
| Enter | Send message / Enter conversation |
| Shift+Enter | New line in message |
| Backspace | Delete selected conversations (with confirmation) |
| Escape | Close dialogs |

## Architecture

```
CTTranscriber/
  App/          — App entry, AppDelegate, About window
  Models/       — SwiftData models (Conversation, Message, Attachment, BackgroundTask)
  Views/        — SwiftUI views + NSTableView chat (ChatView, ConversationListView, Settings)
  ViewModels/   — @Observable view models (ChatViewModel, SettingsManager)
  Services/     — LLM, Transcription, TaskManager, AudioPlayback, VideoConverter, ModelManager
  Resources/    — Info.plist, default-settings.json, Assets.xcassets
```

**Key technologies:**
- SwiftUI + NSViewRepresentable (NSTableView for chat, AVPlayerView for video)
- SwiftData for persistence
- [metal-faster-whisper](https://github.com/vsevolod-oparin/metal-faster-whisper) (SPM binary xcframework) for in-process Whisper transcription on Apple Silicon Metal GPU — no Python, no subprocess
- SSE streaming for LLM APIs (OpenAI-compatible + Anthropic)

## License

MIT License — see [LICENSE](LICENSE)

## Author

**Vsevolod Oparin** — [GitHub](https://github.com/vsevolod-oparin)
