# ROADMAP: CT Transcriber macOS

A native macOS audio transcription app with LLM chat capabilities, powered by CTranslate2 Metal backend on Apple Silicon.

**CTranslate2 source:** Local build at `/Users/smileijp/projects/branch/CTranslate2` (metal-backend branch). See `METAL_QUICKSTART.md` there for build instructions.

---

## Architecture Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| UI Framework | SwiftUI (NavigationSplitView) | Modern, native macOS sidebar+detail pattern; Xcode 16+ |
| Whisper Integration | Python subprocess (faster-whisper via conda env) | faster-whisper provides VAD, chunking, temperature retries, and segment timestamps out of the box; direct CT2 API lacks VAD (causes hallucinations on silence) and requires ~200 extra lines of manual pipeline code for comparable results; see `reports/planning-whisper-integration-strategy.md` for full analysis |
| Python Environment | Auto-managed conda env with pre-built wheel | Miniconda auto-installed if missing; pre-built CT2 Metal package (1.3 MB) eliminates compilation; zero terminal interaction for end users |
| Persistent Storage | SwiftData | Native to Swift, backed by SQLite, first-class Xcode support, sufficient for chat dialogues |
| File Storage | App Support directory (`~/Library/Application Support/CTTranscriber/files/`) | Unified storage for audio, images, and text files; referenced by UUID filename in SwiftData `Attachment` model |
| Settings Storage | JSON file at `~/Library/Application Support/CTTranscriber/settings.json` | Defaults bundled in app as `default-settings.json`; copied to user config on first launch; all provider configs, API keys, and paths are user-editable |
| LLM Integration | Unified Swift HTTP client with provider adapters | All major LLM APIs follow similar REST/SSE patterns; no need for heavy SDKs |
| Background Tasks | Swift Concurrency (async/await + actors) | Native, structured concurrency with cancellation support |
| Distribution | Unsigned DMG via `create-dmg` | Simple, matches RFC requirement |

### CTranslate2 Metal Backend — Build Reference

The CTranslate2 metal-backend is already developed and buildable locally. The build procedure (from `METAL_QUICKSTART.md`):

```bash
conda create -n whisper-metal python=3.12 -y && conda activate whisper-metal
pip install torch transformers sentencepiece faster-whisper

cd /Users/smileijp/projects/branch/CTranslate2
git submodule update --init --recursive
python3 tools/gen_msl_strings.py

mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DWITH_METAL=ON -DWITH_ACCELERATE=ON \
  -DWITH_MKL=OFF -DWITH_DNNL=OFF -DOPENMP_RUNTIME=NONE \
  -DCMAKE_INSTALL_PREFIX=$(python -c "import sys; print(sys.prefix)")
cd ..
cmake --build build -j$(sysctl -n hw.logicalcpu)
cmake --install build

cd python && pip install . && cd ..
```

Key details:
- Device: `mps` (Metal GPU), compute type: `float16`
- Model conversion uses `ct2-transformers-converter` — **must** include `--copy_files tokenizer.json preprocessor_config.json`
- Performance: Metal GPU is ~3.7x faster than CPU (M4, whisper-large-v3-turbo, 60s audio → 7.4s)

---

## Milestone 0: Project Skeleton & Build System ✅

**Goal:** Xcode project builds and runs, showing an empty window.
**Status:** Complete (2026-03-16) — see `reports/milestone-0-project-skeleton.md`

### Tasks
- [x] Create Xcode project: macOS App, SwiftUI, Swift, SwiftData (via xcodegen + `project.yml`)
- [x] Set deployment target to macOS 14.0+ (Sonoma — required for modern SwiftData)
- [x] Configure project structure:
  ```
  CTTranscriber/
    App/              — App entry point, main window
    Models/           — SwiftData models
    Views/            — SwiftUI views
    ViewModels/       — ObservableObject view models
    Services/         — LLM, Transcription, Storage services
    Resources/        — Assets, bundled scripts
    Python/           — Bundled Python scripts for faster-whisper
  ```
- [x] Add `.gitignore` entries for Xcode build artifacts, DerivedData
- [x] Verify app launches in Xcode 16.2 with blank window

### Test Criteria
- [x] `Cmd+R` in Xcode builds and launches the app without errors
- [x] App shows a window with title "CT Transcriber"

---

## Milestone 1: Chat UI Shell (No Backend) ✅

**Goal:** ChatGPT-like UI with sidebar and chat area, using mock data.
**Status:** Complete (2026-03-16) — see `reports/milestone-1-chat-ui-shell.md`

### Tasks
- [x] Implement `NavigationSplitView` with collapsible sidebar
- [x] Sidebar: list of conversations with title, date, delete action
- [x] Main area: scrollable message list (user/assistant bubbles)
- [x] Text input bar at bottom with send button
- [x] Attachment button (audio file picker — non-functional placeholder)
- [x] New conversation button in sidebar
- [x] Empty state when no conversation is selected
- [x] Rename conversation (right-click → Rename, inline editing in sidebar)
- [x] Use mock in-memory data (no persistence yet)

### Test Criteria
- [x] Sidebar shows mock conversations; selecting one displays messages
- [x] Sidebar can be collapsed/shown via toolbar button
- [x] Typing text and pressing Send adds a user bubble to the chat
- [x] New conversation creates an entry in sidebar
- [x] Delete conversation removes it from sidebar

---

## Milestone 2: Persistent Storage (SwiftData) ✅

**Goal:** Conversations and messages persist across app restarts.
**Status:** Complete (2026-03-16) — see `reports/milestone-2-persistent-storage.md`

### Tasks
- [x] Define SwiftData models:
  - `Conversation`: id, title, createdAt, updatedAt
  - `Message`: id, role (user/assistant/system), content, timestamp, audioFilePath?, conversation relationship
- [x] Wire ChatViewModel to `ModelContext` with fetch by updatedAt descending
- [x] Wire chat view to sorted messages via view model
- [x] Save messages on send
- [x] Auto-generate conversation title from first message (truncated at 50 chars)
- [x] File storage: copy attachments to `~/Library/Application Support/CTTranscriber/files/{uuid}.{ext}`
- [x] `Attachment` model (kind: audio/video/image/text, storedName, originalName) with cascade delete from Message
- [x] Support attaching audio, video, images, and text files (txt, md, py, cpp, etc.)
- [x] Clean up stored files on conversation delete

### Test Criteria
- [x] Create conversation, add messages, quit app, relaunch — data persists
- [x] Delete conversation — messages and referenced audio files are cleaned up
- [x] Attach an audio file — file is copied to app storage, reference appears in message

---

## Milestone 3: Settings Infrastructure ✅

**Goal:** Settings UI and JSON-based persistence.
**Status:** Complete (2026-03-16) — see `reports/milestone-3-settings-infrastructure.md`

### Tasks
- [x] Create Settings window (SwiftUI `Settings` scene, 3-tab TabView)
- [x] Settings model with JSON Codable, stored at `~/Library/Application Support/CTTranscriber/settings.json` (or `~/.config/ct-transcriber/` if writable)
- [x] Default provider configs in bundled `Resources/default-settings.json` — no hardcoded configs in code; users can share/edit the JSON file directly
- [x] Tabs:
  - **General**: app theme (light/dark/system)
  - **Transcription**: environment (conda env, CT2 source/package URL, models dir), inference (device, beam size, temperature, language, VAD, condition)
  - **LLM**: data-driven provider configs (add/remove/edit), per-provider: name, API type, base URL, paths, API key, model picker with fetch, extra headers, temperature, max tokens
- [x] API keys stored in settings.json (plaintext, industry standard for LLM tools)
- [x] All provider configs in `default-settings.json` (bundled) — no hardcoded URLs, paths, or headers in Swift code
- [x] Settings observable via `@Observable` SettingsManager, injected into environment
- [x] Theme applied via `preferredColorScheme`
- [x] Inline validation errors (red text) for out-of-range values

### Test Criteria
- [x] Open Settings, change transcription beam size, close and reopen — value persists
- [x] API key saved in settings.json, retrievable after app restart
- [x] Invalid settings (e.g., beam size = 0) show validation error
- [x] Settings JSON file is human-readable at expected path

---

## Milestone 4: LLM API Integration ✅

**Goal:** Send messages to LLM providers and stream responses.
**Status:** Complete (2026-03-16) — see `reports/milestone-4-llm-api-integration.md`

### Tasks
- [x] Define `LLMService` protocol with `streamCompletion()` → `AsyncThrowingStream<String, Error>`
- [x] Implement providers:
  - [x] `OpenAICompatibleService` (OpenAI, DeepSeek, Qwen, Z.ai — `/v1/chat/completions` SSE)
  - [x] `AnthropicService` (Claude — `/v1/messages` SSE with `content_block_delta`)
- [x] `LLMServiceFactory` maps provider enum → service implementation
- [x] Streaming response: tokens appear in real-time, "Thinking..." placeholder before first token
- [x] Error handling: inline error banner with dismiss, covers no-key/network/HTTP errors
- [x] Stop/cancel streaming: send button becomes red Stop button during inference; cancels URLSession, preserves partial text
- [x] Conversation context: full message history sent with each request
- [x] Auto-name conversations: after first assistant response, background LLM request for a short title

### Test Criteria
- [x] Configure OpenAI API key, select model, send "Hello" — get streamed response
- [x] Configure Anthropic API key, select Claude — get streamed response
- [x] Configure DeepSeek/Qwen/Z.ai endpoint (OpenAI-compatible) — get response
- [x] Press Stop during streaming — response stops, partial text preserved, send button restored
- [x] No API key configured — clear error message, not a crash
- [x] Network offline — graceful error in chat

---

## Milestone 5: Python/CTranslate2 Environment Setup ✅

**Goal:** Conda environment with faster-whisper and CTranslate2 metal-backend, callable from Swift.
**Status:** Complete (2026-03-16) — see `reports/milestone-5-python-env-setup.md`

The CTranslate2 metal-backend source is at `/Users/smileijp/projects/branch/CTranslate2` and builds per `METAL_QUICKSTART.md`.

### Tasks
- [x] Create environment setup script (`setup_env.sh`) that automates the METAL_QUICKSTART flow:
  - Check for conda/miniconda (prompt to install if missing)
  - Create `whisper-metal` conda env (Python 3.12)
  - `pip install torch transformers sentencepiece faster-whisper`
  - Build CTranslate2 from local source with Metal+Accelerate:
    ```bash
    cd /path/to/CTranslate2
    git submodule update --init --recursive
    python3 tools/gen_msl_strings.py
    cmake -B build -DCMAKE_BUILD_TYPE=Release -DWITH_METAL=ON -DWITH_ACCELERATE=ON \
      -DWITH_MKL=OFF -DWITH_DNNL=OFF -DOPENMP_RUNTIME=NONE \
      -DCMAKE_INSTALL_PREFIX=$(python -c "import sys; print(sys.prefix)")
    cmake --build build -j$(sysctl -n hw.logicalcpu)
    cmake --install build
    cd python && pip install . && cd ..
    ```
  - Report progress for each step via JSON stdout
- [x] Create `transcribe.py` CLI wrapper:
  - JSON-over-stdout protocol: info → segments → done (or error)
  - Progress on stderr: `[progress] Transcribing... 45%`
  - Device mps/cpu, beam size, temperature, language, VAD, condition args
- [x] Swift `PythonEnvironment` service:
  - Detect conda + env, validate imports, return `.ready(pythonPath)` or `.missing(reason)`
  - `runSetup()` → `AsyncThrowingStream<SetupStep, Error>` for progress
- [x] Environment paths in settings.json: condaEnvName, ctranslate2SourcePath, modelsDirectory
- [x] Settings UI: Environment section with Browse buttons for paths

### Test Criteria
- [x] `setup_env.sh` creates conda env, imports succeed
- [x] `transcribe.py` produces JSON transcript with segments
- [x] `--device mps` uses Metal GPU; `--device cpu` falls back
- [x] Swift app detects missing env via `PythonEnvironment.check`
- [x] Setup streams progress via JSON steps

---

## Milestone 5b: Zero-Setup User Experience ✅

**Goal:** End user installs the DMG, launches the app, and the Python environment sets itself up automatically — no terminal, no Xcode CLT, no manual conda install.
**Status:** Complete (2026-03-16) — see `reports/milestone-5b-zero-setup-ux.md`

### Strategy

Two complementary approaches:

**1. Pre-built CTranslate2 Metal wheel**
- Build a `.whl` for the metal-backend on arm64 macOS once (on the developer's machine or CI)
- Host on GitHub Releases or a simple HTTP server
- Setup script becomes: `pip install ctranslate2-metal-X.Y.Z-cp312-arm64.whl` instead of compiling from source
- Eliminates: Xcode CLT, cmake, 5+ minute build time
- User still needs conda/miniconda for the Python env

**2. Bundled Miniconda installer**
- On first launch, if conda is not detected:
  - Download Miniconda arm64 installer (~60 MB) from `https://repo.anaconda.com/miniconda/`
  - Install silently to `~/Library/Application Support/CTTranscriber/miniconda/`
  - Create the whisper-metal env there
  - All automatic — user only sees a progress bar
- Eliminates: manual conda installation

Together these mean: user opens app → progress bar → ready. No terminal commands ever.

### Tasks

**Pre-built wheel:**
- [x] Build CTranslate2 metal-backend wheel (421 KB) + dylib (3.4 MB) → 1.3 MB archive
- [x] Archive hosted at `https://github.com/vsevolod-oparin/ct-transcriber-macos/releases/download/dev/ctranslate2-4.7.1-cp312-cp312-macosx_14_0_arm64.whl.tar.gz`
- [x] `setup_env.sh` wheel mode: download archive → pip install wheel → copy dylib
- [x] Source-build path preserved as fallback (`--source` flag)

**Bundled Miniconda:**
- [x] Auto-download Miniconda arm64 (~60 MB) and silent install to `~/Library/Application Support/CTTranscriber/miniconda/`
- [x] `PythonEnvironment` searches bundled Miniconda path first

**First-launch flow (Swift UI):**
- [x] `PythonEnvironment.check()` runs on app launch
- [x] If missing: `EnvironmentSetupView` sheet with progress, cancel, retry
- [x] If ready: no prompt
- [x] Settings → "Re-run Environment Setup..." button
- [x] `ct2PackageURL` configurable in settings.json

### Test Criteria
- [x] setup_env.sh installs Miniconda + wheel without compilation
- [x] Source build fallback still works
- [x] First-launch sheet shows step-by-step progress
- [x] Cancel and retry work
- [x] "Re-run Setup" in settings works
- [ ] End-to-end test on fresh machine (archive hosted, needs clean-machine test)

---

## Milestone 6: Model Management ✅

**Goal:** Download, convert, and manage Whisper models from within the app.
**Status:** Complete (2026-03-16) — see `reports/milestone-6-model-management.md`

### Tasks
- [x] Model registry in `default-settings.json` (data-driven, user-editable):

  | Model | HuggingFace ID | Size | Speed | Quality |
  |-------|---------------|------|-------|---------|
  | large-v3-turbo | `openai/whisper-large-v3-turbo` | ~1.6 GB | Fastest | Great |
  | large-v3 | `openai/whisper-large-v3` | ~3.1 GB | Slower | Best |
  | base | `openai/whisper-base` | ~150 MB | Very fast | Good for testing |

- [x] `convert_model.py` script: downloads from HuggingFace + converts to CTranslate2 format
  - Enforces `--copy_files tokenizer.json preprocessor_config.json`
  - Validates output (model.bin, tokenizer.json, preprocessor_config.json)
  - JSON progress reporting
- [x] Models stored in `~/Library/Application Support/CTTranscriber/models/{model-id}/` (configurable)
- [x] `ModelManager` service (`@Observable`): download, cancel, delete, status tracking per model
- [x] Model Manager UI sheet: list models with status, download/cancel/delete buttons, selection indicator
- [x] `selectedModelID` in settings, model picker in Transcription tab
- [x] "Manage Models..." button in Settings → Transcription

### Test Criteria
- [x] Model manager shows available models with status
- [x] Download model — progress shown, completes
- [x] Downloaded model shows size and "Ready" status
- [x] Delete model — files removed, status updates
- [x] Select model in settings — stored as selectedModelID

---

## Milestone 7: Audio Transcription Pipeline ✅

**Goal:** Attach audio file, transcribe it, show results in chat.
**Status:** Complete (2026-03-17) — see `reports/milestone-7-transcription-pipeline.md`

### Tasks
- [x] `TranscriptionService`: runs `transcribe.py` subprocess, parses JSON segments, streams progress
- [x] Auto-transcribe: attaching audio/video triggers transcription automatically
- [x] Progress bar with percentage + stop button above input bar
- [x] Placeholder message updates during transcription, final result with timestamps
- [x] Transcription settings applied (beam, temperature, language, VAD, device)
- [x] Preflight checks: Python env ready, model downloaded
- [x] Cancellation: stop button kills the task

### Test Criteria
- [x] Attach audio → transcription completes, timestamped text in chat
- [x] Progress bar shows during transcription
- [x] Cancel transcription → stops, message shows "cancelled"
- [x] Audio/video attachment auto-triggers transcription
- [x] No model → error message shown
- [x] Settings (beam, temp) applied

---

## Milestone 7b: Chat UX Improvements (partial ✅)

**Goal:** Make long conversations and large transcription bubbles usable.
**Status:** Partially complete (2026-03-17) — see `reports/milestone-7b-chat-ux-improvements.md`
Performance optimization and some player features deferred.

### Tasks

**Collapsible bubbles:**
- [x] Long messages (>15 lines) auto-collapse, show first 5 lines + "Show more (N lines)"
- [x] Click to expand/collapse with animation
- [x] Streaming messages always expanded
- [x] "Show more" button visible on user messages (white on blue) and assistant messages (accent color)

**Bubble copy:**
- [x] Copy button on hover — left of user messages, right of assistant messages (not overlapping content)
- [x] Right-click context menu: "Copy" and "Copy without timestamps" (for transcription results)
- [x] Copies full message text to clipboard

**Message input:**
- [x] Scrollable multi-line input using TextEditor (grows up to ~5 lines, then scrolls)
- [x] Placeholder "Message..." aligned with cursor baseline
- [x] Enter to send, Shift+Enter for newline

**Flash attention:**
- [x] `flash_attention` flag wired through: settings.json → Settings UI toggle → transcribe.py → WhisperModel
- [x] **Fixed**: threadgroup memory alignment bug resolved in CTranslate2 metal-backend. Default: **on**
- [x] **Benchmarked**: flash attention is 1.9–5% *slower* on Metal (tested on 60s and 83min audio, whisper-large-v3-turbo). Default: **off**. 83min audio: 595s without flash vs 606s with flash. See `reports/research-flash-attention-timestamps.md`
- [x] **Timestamps mode stable**: no state corruption detected with current CT2 4.7.1 build (direct API test)

**Transcription speed option:**
- [x] "Skip Timestamps (faster)" toggle in Settings → Transcription
- [x] Passes `--skip-timestamps` → `without_timestamps=True` to faster-whisper
- [x] Plain text output (no `[start → end]`) when timestamps off
- [x] **Benchmarked**: skipping timestamps gives 22% speedup (13.4s vs 17.2s on 60s audio)
- [x] **Timestamps bug not reproduced**: direct CT2 API test shows no state corruption with current build (4.7.1)

**Audio/video player:**
- [x] Inline play/pause button on audio and video attachments
- [x] AVAudioPlayer for playback from stored file
- Remaining player features moved to M7b+ (seek bar, video thumbnail, timestamp sync, visibility-based pause)

**Message status & retry:**
- [x] LLM errors kept as messages (⚠ prefix) with red-tinted background, not just banner
- [x] No-API-key creates error message directly in chat
- [x] Error icon + "Retry" button in timestamp row + right-click context menu
- [x] Retry logic: deletes failed message, re-triggers LLM or re-sends user message

**LLM API key test:**
- [x] "Test Connection" button in Settings → LLM → Authentication
- [x] Sends minimal request ("Hi", max_tokens=1), shows spinner → green checkmark or red error
- [x] Test result resets when switching providers
- [x] API key field stays single-line regardless of key length

**Performance optimization for large conversations:**
- [x] `MessageAnalysis` struct: pre-computes isError, lineCount, isLong, collapsedPreview, hasTimestamps once per content change (not on every render). Uses early-exit newline counting instead of `components(separatedBy:)`.
- [x] `LargeTextView` (NSTextView): messages >5K chars render via NSTextView instead of SwiftUI Text — full content displayed, scrollable within the bubble (max 400px height), selectable. No truncation.
- [x] Auto-scroll only during streaming (not on every content change when browsing)
- [x] Content change detection via `.count` instead of full string comparison
- Further optimization moved to M8c (NSTableView migration)

### Test Criteria
- [x] Long message collapses by default, expands on click (both user and assistant)
- [x] Copy button on bubble → full text in clipboard
- [x] Failed LLM message shows error state with Retry button; retry re-sends successfully
- [x] "Test Connection" in Settings with valid key → green checkmark; with invalid key → error message
- [x] Large transcription bubbles collapse by default, full text via NSTextView when expanded
- [x] Scrolling through conversations smooth (no re-scan on every render)
- [x] Conversation switching starts at bottom (`.defaultScrollAnchor(.bottom)` + view recreation)
- [x] Cmd+Up scrolls to top of conversation
- [x] **Fixed in M8c**: Cmd+Down scroll-to-bottom now reliable (NSTableView `scrollRowToVisible`)
- [x] **Fixed in M8c**: expand/collapse preserves scroll position (saves/restores `bounds.origin`)

---

## Milestone 8: Background Task Manager ✅

**Goal:** All long-running tasks (downloads, transcriptions) are managed in a unified task system.
**Status:** Complete (2026-03-17) — see `reports/milestone-8-background-task-manager.md`

### Tasks
- [x] `TaskManager` with persistent task queue (SwiftData `BackgroundTask` model)
  - Task states: pending, running, completed, failed, cancelled
  - Task types: transcription, modelDownload, pythonSetup
  - Crash recovery: running tasks marked failed on relaunch
- [x] Task manager sheet UI:
  - List all tasks with status, progress, type icons, timestamps
  - Actions: cancel (running), delete, clear completed
- [x] Toolbar badge showing active task count (red circle)
- [x] Transcription creates `BackgroundTask` entry with real-time progress
- [x] Task recovery on app launch: previously-running tasks marked failed
- [x] Multiple audio attachments queue sequentially — transcription placeholder appears right after each audio message
- [x] Configurable max parallel transcriptions (Settings → Transcription, default 1, range 1–4)
- [x] Queue auto-starts next transcription when a slot opens

### Test Criteria
- [x] Transcription visible in task manager with progress
- [x] Force-quit during transcription, relaunch — task marked failed
- [x] Cancel task — status updated
- [x] Delete completed task — removed from list
- [x] Task badge shows active count
- [x] Attach multiple audios — each gets a placeholder immediately after its audio, transcribed one by one

---

## Milestone 8b: Performance & Architecture (from TelegramSwift Research) ✅

**Goal:** Apply high-value patterns from TelegramSwift analysis to improve performance, reliability, and testability.
**Status:** Complete (2026-03-17) — see `reports/milestone-8b-performance-architecture.md`, `reports/research-telegramswift-best-practices.md`

### Immediate Fixes ✅

**Scroll performance during streaming:**
- [x] Throttle scroll-to-bottom during streaming — every 50 characters instead of every character; also scroll on stream end

**MessageAnalysis caching:**
- [x] Throttle `MessageAnalysis` recomputation during streaming — only recompute every 500 chars or on stream finish (not per token)

**Main thread safety:**
- [x] Move `PythonEnvironment` validation off main thread — now runs via `Task.detached` in ContentView
- [x] Move `ModelManager.directorySize()` to background — now runs via `Task.detached(priority: .utility)`, UI shows 0 MB briefly then updates

**Task lifecycle:**
- [x] Clean up `transcriptionTasks` dictionary entries when conversation is deleted — cancels active tasks, removes pending queue entries
- [x] Add `deinit` logging to ChatViewModel, TaskManager, ModelManager — logs to "lifecycle" category

### Architecture Improvements ✅

- [x] Add `TaskManagerProtocol` — enables mock injection for unit tests
- [x] Constructor-based DI for ChatViewModel — `init(modelContext:settingsManager:modelManager:)`, taskManager still post-init (created after VM)
- [x] Add log rotation to `AppLogger` — max 10MB, keep 3 rotated files (.1, .2, .3)

### Test Criteria
- [x] Streaming a 10K-char response: no visible scroll stutter (throttled to 50-char intervals)
- [x] Switch conversations during streaming: no leaked tasks or stale state (cleanup on delete)
- [x] App launch: no main thread freeze during Python validation (async check)

---

## Milestone 8c: NSTableView Chat Migration

**Goal:** Replace LazyVStack+ScrollView with NSTableView for the chat message list. Fixes all known scroll issues and enables Telegram-level performance for large conversations.
**Status:** Complete (2026-03-17) — see `reports/milestone-8c-nstableview-migration.md`

### Background (from TelegramSwift Research)

Telegram's chat is built on a heavily customized NSTableView with:
- `layerContentsRedrawPolicy = .never` — no automatic layer redraws
- `usesAutomaticRowHeights = false` — all heights cached, recomputed only on width change
- `isCompatibleWithResponsiveScrolling = true` — async content rendering during scroll
- Cell reuse via identifier pool (`makeView(withIdentifier:)`)
- `TableUpdateTransition` with diff-based insert/update/delete (no full reload)
- `animateVisibleOnly` flag — only animates rows in viewport
- ID-based scroll preservation (`TableScrollState.saveVisible`) — survives message loading

### Tasks

- [x] Create `ChatTableView` NSViewRepresentable wrapping NSTableView (`ChatNSTableView` subclass)
- [x] NSHostingView cells wrapping existing SwiftUI MessageBubble views
- [x] Cache row heights per message ID, invalidate on width change; large expanded text measured via NSTextStorage directly
- [x] Scroll position preservation on expand/collapse — saves/restores exact `bounds.origin` so viewport doesn't move
- [x] Diff-based updates: append-only fast path (most common), targeted single-row reload for streaming, full reload only for deletions/reorders
- [x] In-place cell content update on expand/collapse (no cell reload = no flash)
- [x] Fix Cmd+Down scroll-to-bottom — now uses `scrollRowToVisible(lastRow)` (reliable, no height estimation)
- [x] Fix expand/collapse scroll anchoring — viewport stays pinned, bubble expands downward
- [x] `layerContentsRedrawPolicy = .never` from TelegramSwift research
- [x] Streaming scroll throttle (200ms) via coordinator
- [x] `isExpanded` state managed in coordinator's `expandedMessages: Set<UUID>` (survives cell reuse)
- [ ] `isDynamicContentLocked` — disable LargeTextView layout recalculation during rapid scroll (future optimization)

### Test Criteria
- [x] Cmd+Down reliably scrolls to bottom
- [x] Expand/collapse message preserves scroll position (no viewport jump)
- [x] Streaming tokens appear without scroll stutter
- [x] Conversation switching starts at bottom
- [ ] 1000+ messages in a conversation: smooth scroll, no jank (not yet tested at scale)

---

## Milestone 7b+: Audio Player & Media Improvements ✅

**Goal:** Enhanced audio/video playback and media display.
**Status:** Complete (2026-03-18) — see `reports/milestone-7b-plus-audio-media.md`

### Tasks

**Audio player:**
- [x] Seek bar and duration display — Slider with draggable position, current/total time display (m:ss)
- [x] Single-audio enforcement — `AudioPlaybackManager` pauses previous audio/video when new one starts
- [x] Persistent playback position — saved in SwiftData `Attachment.playbackPosition`, survives app restart

**Video player:**
- [x] Native AVPlayerView with inline controls (play/pause, scrub, fullscreen)
- [x] Aspect-ratio-aware sizing — synchronous detection via `AVAssetTrack.naturalSize`, correct for vertical/wide videos
- [x] Video placeholder frame — reserves correct height before player loads (fixes row height measurement)
- [x] WebM/MKV support — auto-converts to MP4 via ffmpeg (from bundled conda env); transcription uses original file

**Image attachments:**
- [x] Inline image preview with aspect-fit, max 200px height

**Floating mini-player:**
- [x] Compact player bar above input when playing media is scrolled out of view
- [x] Play/pause, seek slider, time display, filename
- [x] Works for both audio and video (audio-only controls for video)
- [x] `AudioPlaybackManager` retains player object, polls current time via timer
- [x] Per-conversation — hidden on conversation switch, playback stopped

**Transcript interaction:**
- [x] Right-click transcript → "Play from [timestamp]" — seeks audio to first timestamp in transcript
- [x] Seek infrastructure — `seekRequest` binding wired from ViewModel → ChatTableView → MessageBubble → AudioPlayerView/VideoPlayerView
- [x] Duration format: `ss.s` / `mm:ss.s` / `hh:mm:ss.s` (adaptive, no trailing "s")

**Reliability:**
- [x] No-audio-track detection — pre-flight check via `AVAsset.tracks(withMediaType: .audio)` before transcription
- [x] Smart retry — Retry button detects transcription failures vs LLM failures, re-triggers appropriate action
- [x] Triple error wrapping removed — clean error chain from Python → Swift → UI
- [x] Graceful handling of malformed audio info ("tuple index out of range") in transcribe.py

**Deferred:**
- [ ] Click transcript timestamp to seek (line-level UI — infrastructure ready via `seekRequest`)
- [ ] Visibility-based audio playback pause (needs scroll delegate integration)
- [ ] `NSCache` for thumbnails (current in-memory loading sufficient at scale)

### Test Criteria
- [x] Seek bar shows duration, allows dragging to position
- [x] Video attachment shows correct aspect ratio (horizontal and vertical)
- [x] WebM converts to MP4 and plays
- [x] Image attachment shows inline preview
- [x] Mini-player appears when playing audio/video scrolls out of view
- [x] Retry on transcription failure re-transcribes (not re-sends to LLM)
- [x] File with no audio track shows clear error message

---

## Milestone 9: macOS Integration ✅

**Goal:** Open audio files with the app from Finder, system-level integration.
**Status:** Complete (2026-03-17) — see `reports/milestone-9-macos-integration.md`

### Tasks
- [x] Register app as handler for audio/video file types in `Info.plist`:
  - Audio: `public.audio`, `public.mp3`, `com.apple.m4a-audio`, `com.microsoft.waveform-audio`, `org.xiph.flac`, `public.aiff-audio`, `com.apple.coreaudio-format`
  - Video: `public.movie`, `public.mpeg-4`, `com.apple.quicktime-movie`, `public.avi`, `org.webmproject.webm`, `org.matroska.mkv`
  - Role: Viewer, Rank: Alternate (doesn't hijack default handlers)
- [x] Handle file-open events via `AppDelegate.application(_:open:)` — routes to existing window, no duplicate windows
- [x] `openFiles(urls:)` in ChatViewModel — creates new conversation titled from first filename, attaches all files, auto-transcribes audio/video
- [x] Drag-and-drop into chat message area — native NSTableView drag delegate (`validateDrop` + `acceptDrop`)
- [x] Drag-and-drop onto input bar — `.onDrop` on TextEditor, attaches files instead of pasting path
- [x] Drag-and-drop onto empty state (no conversation selected) — creates new conversation
- [x] Drag-and-drop onto Dock icon — handled by document type registration + AppDelegate
- [x] Single-window enforcement — `AppDelegate` reuses existing window, "New Window" removed from File menu
- [x] Content-change detection via `contentLengthSnapshot` — fixes stale row heights after transcription completes (SwiftData reference-type bug)
- [ ] Share extension (optional, deferred) — "Open in CT Transcriber" in Finder share menu

### Test Criteria
- [x] Right-click audio file in Finder → Open With → CT Transcriber → reuses existing window
- [x] Drag audio file into chat area → attaches and starts transcription
- [x] Drag audio file onto input bar → attaches (not pasted as path text)
- [x] Drag files onto empty state → creates new conversation with files
- [x] Open multiple files at once → batched into one conversation
- [x] Transcription result shows collapsed preview (header + 3 lines) immediately after completion
- [ ] Double-click audio file (if set as default) — requires user to manually set default app

---

## Milestone 9b: Sidebar & UI Polish ✅

**Goal:** Enhanced sidebar navigation, font scaling, appearance improvements.
**Status:** Complete (2026-03-18) — see `reports/milestone-9b-sidebar-ui-polish.md`

### Sidebar Multi-Select & Navigation
- [x] Multi-select with Shift+Arrow, Cmd+Click, Shift+Click (range selection)
- [x] Separate highlight (keyboard) from active (detail view) — click enters, arrows navigate
- [x] Enter key activates highlighted conversation + focuses input
- [x] Backspace deletes highlighted conversations with confirmation dialog (Enter confirms, Esc cancels)
- [x] Tab toggles focus between sidebar and input bar (detects current focus via `NSTextView` responder check)
- [x] Sidebar retains focus after clicking a conversation (reclaims `NSOutlineView` first responder)
- [x] Double-click on title text to rename (uses `NSApp.currentEvent?.clickCount`, no delay)
- [x] Double-click on toolbar title to rename (inline `TitleRenameField` NSViewRepresentable)
- [x] Keyboard events pass through to rename field (Enter/Esc/Backspace not intercepted during editing)
- [x] Cmd+Up/Down scroll chat from any focus context (sidebar or input)
- [x] Click on chat area background focuses input

### Font Scaling
- [x] Cmd+Plus / Cmd+Minus / Cmd+0 — increase, decrease, reset font size (View menu commands)
- [x] Settings → General — slider from 70% to 200% with Reset button
- [x] `ScaledFont` struct with `.body`, `.headline`, `.caption`, `.caption2`, `.title2`, `.title3`
- [x] `fontScale` environment key propagated to all views including NSHostingView cells
- [x] All fonts in ChatView, ConversationListView, SettingsView, TaskManagerView use `ScaledFont`
- [x] NSTextView (LargeTextView, TitleRenameField) font sizes scale
- [x] Paddings, spacings, intercell spacing scale with `fontScale`
- [x] Settings window frame scales with font
- [x] Persisted in `settings.json` as `fontScale`

### Appearance
- [x] Assistant bubble background changed to `unemphasizedSelectedContentBackgroundColor` (better contrast in light mode)
- [x] Timestamps, filenames, attachment badges use `.primary` foreground (was `.secondary`/`.tertiary`)
- [x] Sidebar dates use explicit `NSColor.secondaryLabelColor`
- [x] Empty states ("No Tasks", "No Conversation Selected") use custom scaled views (not `ContentUnavailableView`)

### Task Manager
- [x] Enter and Escape close the task manager sheet
- [x] Task rows show: status prefix (Transcribing/Transcribed/Failed), original filename, conversation title, truncated UUID
- [x] Blue focus ring removed (`.focusEffectDisabled()`)
- [x] Fonts scale with fontScale

### NSTableView Performance (from TelegramSwift audit)
- [x] Height caching — `heightCache: [UUID: CGFloat]` with targeted invalidation
- [x] Cache invalidated on: content change, expand/collapse, font scale change, window resize, conversation switch
- [x] Resize handling via `viewDidEndLiveResize` (Telegram pattern) — no mid-resize updates
- [x] `isLiveResizing` flag suppresses `updateNSView` during drag
- [x] First render data in `makeNSView` + deferred `reloadData` — fixes empty first conversation

### Test Criteria
- [x] Multi-select 5+ conversations with Shift+Arrow, delete with Backspace
- [x] Tab cycles cleanly between sidebar and input (no "nowhere" state)
- [x] Cmd+Plus scales all text proportionally
- [x] Window resize recalculates row heights correctly after drag ends
- [x] Rename via double-click works in both sidebar and toolbar title

---

## Milestone 10: Polish & Distribution ✅

**Goal:** App is ready for distribution as unsigned DMG.
**Status:** Complete (2026-03-18) — see `reports/milestone-10-polish-distribution.md`

### Tasks
- [x] App icon — `waveform.circle.fill` on light blue gradient, Apple HIG 10% margin, all macOS sizes
- [x] About window — version, build, author (Vsevolod Oparin), GitHub link, credits (Help menu)
- [x] Per-conversation LLM streaming — `streamingTasks: [UUID: Task]`, fully isolated, multiple simultaneous
- [x] Main-thread blocking audit — AVAsset async, image loading async, video aspect ratio pre-computation
- [x] Ollama local LLM support — pre-configured provider at localhost:11434
- [x] README.md — features, installation, architecture, shortcuts
- [x] LICENSE — MIT, Copyright 2026 Vsevolod Oparin
- [x] Menu bar:
  - File → New Conversation (Cmd+N), Open Audio/Video (Cmd+O)
  - View → Increase/Decrease/Reset Font Size (Cmd+/Cmd-/Cmd+0)
  - CT Transcriber → About
  - Settings (Cmd+,) — automatic from SwiftUI Settings scene
- [x] Keyboard shortcuts: Cmd+N, Cmd+O, Cmd+,, Cmd+Plus/Minus/0, Cmd+Q
- [x] First-launch onboarding — EnvironmentSetupView with progress (M5b)
- [x] Error states — custom empty states, inline error messages, error prefixes
- [x] Dark mode — native SwiftUI `.preferredColorScheme`
- [x] DMG creation script: `scripts/create-dmg.sh`
  - Builds Release configuration
  - Creates DMG with Applications symlink + README
  - Documents Gatekeeper bypass
- [x] README in DMG with installation instructions

### Test Criteria
- [x] All keyboard shortcuts work (Cmd+N, Cmd+O, Cmd+,, Cmd+Q)
- [x] Dark mode looks correct
- [x] First launch guides user through setup
- [x] About window shows version info
- [x] DMG creation tested end-to-end
- [x] App launches from Applications (after Gatekeeper bypass) — documented in M11

---

## Milestone 11: Distribution Hardening & Installation UX (v0.2.0) ✅

**Goal:** Make the app reliably installable and usable on other Macs, with robust setup and proper uninstall.
**Status:** Complete (2026-03-19) — see `reports/milestone-11-distribution-hardening.md`

### Tasks

**Distribution & Gatekeeper:**
- [x] Investigate and document Gatekeeper quarantine issue (Telegram/browser downloads)
- [x] Custom app icon (robot) with proper 9% padding, all macOS sizes
- [x] Version bump to 0.2.0

**Uninstaller:**
- [x] `uninstall.sh` standalone script — removes app, data, conda env, config, preferences, SwiftData store
- [x] In-app Help → Uninstall CT Transcriber — confirmation alert (Enter/Escape), spinner overlay
- [x] Non-blocking uninstall — shell process polls for app PID exit, then deletes (no timing hacks)

**Setup script hardening:**
- [x] Fix `set -euo pipefail` killing script on non-fatal ffmpeg failure (`|| true` + `--override-channels`)
- [x] Full stderr logging (was `FileHandle.nullDevice`) — all conda/pip/curl errors now in log file
- [x] Granular progress steps: download/install miniconda split, torch checkpoint, CT2 download/install split
- [x] Parallel installation: torch + faster-whisper + ffmpeg run concurrently (~2x faster)
- [x] Auto model download: whisper-large-v3-turbo downloaded during setup with HuggingFace prefetch
- [x] Immediate "Starting environment setup..." message before shell starts

**Setup UI:**
- [x] Spinner always visible during setup (was disappearing between steps)
- [x] Step label persists until next step starts (no blank gaps)
- [x] No duplicate display (completed steps in list, active step next to spinner only)
- [x] `ModelManager.refreshStatuses()` on setup dismiss

**Runtime fix:**
- [x] Remove `DYLD_LIBRARY_PATH` override — was breaking PyAV/libiconv (`_iconv` symbol not found)

**Main-thread blocking:**
- [x] `AppUninstaller` — non-blocking (background shell process)
- [x] `ModelManager.deleteModel()` — `Task.detached`
- [x] `ChatViewModel.attachFile()` — `Task.detached` for file copy

### Test Criteria
- [x] App installs and runs on another Mac after `xattr -cr`
- [x] Setup completes with parallel installs, model auto-downloaded
- [x] Uninstall removes all data including conda env (~500MB)
- [x] Transcription works (DYLD_LIBRARY_PATH fix)
- [x] No UI blocking during uninstall, model delete, or file attach

---

## Milestone 11b: Audit Fixes & Code Quality ✅

**Goal:** Fix all issues found in the comprehensive 6-agent audit.
**Status:** Complete (2026-03-19) — see `reports/milestone-11b-audit-fixes.md`, `reports/audit-v0.2.0-comprehensive.md`

### Audit Scope
6 parallel agents audited: UI/UX, async/concurrency, data model/logic, performance, architecture, TelegramSwift comparison. 44 issues found.

### Fixes Applied (22/44)

**CRITICAL (4/4):**
- [x] Command injection in AppUninstaller — paths passed as positional args, not interpolated
- [x] Data races on `streamingConversationIDs` and `transcriptionTasks` — `@MainActor` on ChatViewModel
- [x] Orphaned converted MP4 files on conversation delete — `convertedName` now cleaned up

**HIGH (8/10):**
- [x] Orphaned Python subprocess — `process.terminate()` on cancellation
- [x] Silent `saveContext()` failures — error logging added
- [x] Silent `try?` in FileStorage, TaskManager — error logging added
- [x] String concatenation in streaming hot path — 50-char token batching
- [x] Excessive `refreshConversations()` — 6 redundant calls removed
- [x] No network timeouts — `llmURLSession` with 30s request / 10min resource timeout
- [x] TaskManager data race — `@MainActor` added
- [ ] Subprocess timeout (mitigated by process.terminate())

**MEDIUM (8/18):**
- [x] SwiftData schema versioning — `SchemaV1` + `CTTranscriberMigrationPlan`
- [x] AppLogger thread safety — serial `DispatchQueue` for file I/O
- [x] Empty conversation state — sidebar overlay with "No conversations"
- [x] Font scaling in Settings — hardcoded widths replaced with `fontScale`-computed values
- [x] LLM test connection timeout — shared `llmURLSession`
- [x] `activeTranscriptionCount` race — fixed by `@MainActor`
- [ ] Extract TranscriptionOrchestrator from ChatViewModel (deferred — tightly coupled)
- [ ] Services without protocols (deferred — needed when adding unit tests)

**LOW (2/12):**
- [x] Task Manager keyboard shortcut — Cmd+Shift+B
- [x] AboutView extracted to own file

### Deferred Items (22)
Architecture refactors (M1 TranscriptionOrchestrator, M2 protocols), performance optimizations (M4-M6), TelegramSwift patterns (M16-M18 audio visibility, priority queue, responsive scrolling), polish (L1-L11 VoiceOver, button styles, naming).

---

## Milestone 12 (Future): MCP Support

**Goal:** Extend LLM capabilities with Model Context Protocol tools.

### Tasks (Investigation)
- [ ] Research MCP Swift SDK availability
- [ ] Evaluate MCP tools: image search, maps, drawing
- [ ] Design tool-use UI in chat (tool calls displayed as expandable cards)
- [ ] Implement MCP client connecting to local MCP servers
- [ ] Allow user to configure MCP server endpoints

### Test Criteria
- [ ] MCP server connects successfully
- [ ] Tool call results displayed inline in chat
- [ ] User can enable/disable MCP tools in settings

---

## Milestone 13: Content Export & Markdown ✅

**Goal:** Make media downloadable, render markdown in chat, import/export conversations.
**Status:** Complete (2026-03-20, v0.4.0) — see `reports/milestone-13-content-export-markdown.md`

### Tasks

**Downloadable media:**
- [x] "Save As..." button/context menu on audio, video, and image attachments
- [x] Export transcription text as `.txt`, `.srt` (subtitles), or `.md` file
- [ ] Drag attachment out of the app to Finder (export via drag) — deferred

**Markdown preview:**
- [x] Render markdown in assistant messages (bold, italic, code blocks, lists, headers, tables)
- [x] Option to toggle between raw text and rendered markdown (per-conversation toolbar button)
- [x] Code blocks with copy button (syntax highlighting deferred — needs third-party dep)
- [x] Rendered inline in the bubble (not a separate window) for seamless reading

**Conversation import/export:**
- [x] Export conversation as JSON (messages + metadata, without binary attachments)
- [x] Export conversation as Markdown file (human-readable)
- [x] Export conversation as PDF (formatted with real NSTextTable tables, inline markdown)
- [x] Import conversation from JSON (creates new conversation with history)
- [x] Bulk export: export all conversations as a ZIP archive
- [x] File menu: Export as PDF (Cmd+E), Export as JSON (Cmd+Shift+E), Import (Cmd+Shift+I)

### Test Criteria
- [x] Right-click audio attachment → Save As → saves to chosen location
- [x] Markdown renders correctly (bold, code blocks, lists)
- [x] Export → Import round-trip preserves all messages
- [x] Bulk export creates valid ZIP with all conversations

---

## Future Considerations (from TelegramSwift Research)

Items that don't warrant a milestone yet but should be revisited as the app grows:

- **Priority queue for transcriptions** — user-initiated (manual attach) preempts auto-queued. Relevant when parallel transcription limit is >1 and queue is common.
- **Lite Mode / Low Power settings** — reduce streaming frequency, disable animations, prefer smaller models. Telegram has granular `LiteModeKey` per feature. Relevant if users report battery drain on laptops.
- **Extract Services into local Swift Package** — Telegram has 49 packages. Do this when codebase exceeds ~50 files for cleaner boundaries and faster incremental builds.

---

## Dependency Graph

```
M0 (Skeleton)
 ├── M1 (Chat UI)
 │    └── M2 (Persistence)
 │         ├── M4 (LLM Integration) ← M3 (Settings)
 │         └── M7 (Transcription) ← M5 (Python Env) ← M6 (Models)
 │              ├── M7b (Chat UX) → M8 (Tasks) → M8b (Perf) → M8c (NSTableView) ✅
 │              └── M7b+ (Media Player) ✅
 ├── M3 (Settings) ├── M5b (Zero-Setup) ✅
 ├── M9 (macOS Integration) ✅
 ├── M9b (Sidebar & UI Polish) ✅
 └── M10 (Polish & DMG) ← all above
      └── M11 (Distribution Hardening) ✅
           └── M11b (Audit Fixes) ✅
                └── FSM + Anti-Pattern Audit (v0.3.x) ✅
                     └── M13 (Export & Markdown) ✅ (v0.4.0)
                          └── M12 (MCP) [future]
```

## Suggested Implementation Order

| Phase | Milestones | Status | Focus |
|-------|-----------|--------|-------|
| **Phase A** | M0 → M1 → M2 → M3 | ✅ Done | Core UI + persistence |
| **Phase B** | M4 | ✅ Done | LLM integration (Z.ai, OpenAI, Anthropic, DeepSeek, Qwen) |
| **Phase C** | M5 → M5b | ✅ Done | Python env + zero-setup UX |
| **Phase D** | M6 → M7 | ✅ Done | Model management + transcription pipeline |
| **Phase E** | M7b → M8 → M8b → M8c | ✅ Done | Chat UX + task manager + performance + NSTableView migration |
| **Phase F** | M9 | ✅ Done | macOS integration (Finder, drag-and-drop) |
| **Phase G** | M7b+ | ✅ Done | Audio/video player, seek bar, mini-player, WebM, smart retry |
| **Phase H** | M9b | ✅ Done | Sidebar multi-select, font scaling, UI polish, NSTableView perf audit |
| **Phase I** | M10 | ✅ Done | Polish + DMG distribution |
| **Phase J** | M11 | ✅ Done | Distribution hardening, setup UX, uninstaller (v0.2.0) |
| **Phase J+** | M11b | ✅ Done | 6-agent audit: 22 fixes (security, data races, threading, performance) |
| **Phase K** | FSM + audit | ✅ Done | FSM refactoring, anti-pattern audit, crash fixes, video sizing, PythonEnv caching (v0.3.x) |
| **Phase L** | M13 | ✅ Done | Markdown rendering, PDF/JSON/MD export, import, media save (v0.4.0) |
| **Phase M** | M12 | Future | MCP exploration |

---

## Key Risks

| Risk | Mitigation |
|------|-----------|
| Pre-built wheel compatibility across macOS versions | Build on oldest supported macOS (14.0); test on 14 and 15; include macOS version in wheel filename |
| Miniconda silent install may be blocked by Gatekeeper | Download official installer from repo.anaconda.com (signed); use `-b` (batch) flag |
| Model conversion downloads are large (1-3 GB for large models) | Start with `whisper-base` (~150 MB) for testing; show size warnings; implement resume |
| `preprocessor_config.json` or `tokenizer.json` missing after conversion | Enforce `--copy_files` flag in conversion script; validate model directory completeness |
| Unsigned app triggers Gatekeeper warnings | Document `xattr -cr` bypass; consider $99/yr Developer ID signing for wider distribution |
| LLM API rate limits / costs | Show token usage estimates; support local models in future |
| Bundled Miniconda adds ~500 MB first-launch download | Show clear size estimate in setup dialog; cache the installer |
