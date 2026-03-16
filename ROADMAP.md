# ROADMAP: CT Transcriber macOS

A native macOS audio transcription app with LLM chat capabilities, powered by CTranslate2 Metal backend on Apple Silicon.

**CTranslate2 source:** Local build at `/Users/smileijp/projects/branch/CTranslate2` (metal-backend branch). See `METAL_QUICKSTART.md` there for build instructions.

---

## Architecture Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| UI Framework | SwiftUI (NavigationSplitView) | Modern, native macOS sidebar+detail pattern; Xcode 16+ |
| Whisper Integration | Python subprocess (faster-whisper via conda env) | faster-whisper provides VAD, chunking, temperature retries, and segment timestamps out of the box; direct CT2 API lacks VAD (causes hallucinations on silence) and requires ~200 extra lines of manual pipeline code for comparable results; see `reports/planning-whisper-integration-strategy.md` for full analysis |
| Python Environment | Conda (`whisper-metal` env, Python 3.12) | Matches CTranslate2 METAL_QUICKSTART.md; conda handles native deps cleanly |
| Persistent Storage | SwiftData | Native to Swift, backed by SQLite, first-class Xcode support, sufficient for chat dialogues |
| File Storage | App Support directory (`~/Library/Application Support/CTTranscriber/files/`) | Unified storage for audio, images, and text files; referenced by UUID filename in SwiftData `Attachment` model |
| Settings Storage | JSON file in `~/.config/ct-transcriber/` | XDG-compatible, easy to edit manually, portable |
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
  - **Transcription**: model (base/large-v3-turbo/large-v3), device (mps/cpu), beam size, temperature, language, VAD filter, condition on previous text
  - **LLM**: provider selector (OpenAI/Anthropic/DeepSeek/Qwen), base URL, API key (SecureField → Keychain), model name, temperature, max tokens
- [x] API keys stored in macOS Keychain (not in JSON)
- [x] Settings observable via `@Observable` SettingsManager, injected into environment
- [x] Theme applied via `preferredColorScheme`
- [x] Inline validation errors (red text) for out-of-range values

### Test Criteria
- [x] Open Settings, change transcription beam size, close and reopen — value persists
- [x] API key saved to Keychain, retrievable after app restart
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

## Milestone 5: Python/CTranslate2 Environment Setup

**Goal:** Conda environment with faster-whisper and CTranslate2 metal-backend, callable from Swift.

The CTranslate2 metal-backend source is at `/Users/smileijp/projects/branch/CTranslate2` and builds per `METAL_QUICKSTART.md`.

### Tasks
- [ ] Create environment setup script (`setup_env.sh`) that automates the METAL_QUICKSTART flow:
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
  - Report progress for each step (submodules, cmake, build, install)
- [ ] Create `transcribe.py` CLI wrapper:
  ```
  python transcribe.py --model <path> --audio <path> --beam-size 5 --temperature 0.0 --device mps --output json
  ```
  Output: JSON with segments `[{start, end, text}]`, progress on stderr
  - Use `device=mps`, `compute_type=float16` by default; fall back to `device=cpu`, `compute_type=float32`
  - Support `vad_filter=True`, `condition_on_previous_text`, `language` args
- [ ] Swift `PythonEnvironment` service:
  - Detect conda installation and `whisper-metal` env
  - Provide path to conda env's Python executable
  - Validate: `python -c "import ctranslate2; import faster_whisper"`
  - Run setup if env missing (with progress reporting)
- [ ] First-launch flow: detect missing env, guide user through setup
- [ ] Store CTranslate2 source path in settings (default: bundled or user-configured)

### Test Criteria
- [ ] Run `setup_env.sh` — conda env created, `python -c "import ctranslate2"` succeeds
- [ ] `conda activate whisper-metal && python transcribe.py --model <path> --audio test.wav` produces JSON transcript
- [ ] `transcribe.py --device mps` uses Metal GPU; `--device cpu` falls back to CPU
- [ ] Swift app detects missing env and shows setup prompt
- [ ] Setup completes with visible progress (build steps logged)

---

## Milestone 6: Model Management

**Goal:** Download, convert, and manage Whisper models from within the app.

### Tasks
- [ ] Model registry with recommended models:

  | Model | HuggingFace ID | Size | Speed | Quality |
  |-------|---------------|------|-------|---------|
  | large-v3-turbo | `openai/whisper-large-v3-turbo` | ~1.6 GB | Fastest | Great |
  | large-v3 | `openai/whisper-large-v3` | ~3.1 GB | Slower | Best |
  | base | `openai/whisper-base` | ~150 MB | Very fast | Good for testing |

- [ ] Model conversion via `ct2-transformers-converter` subprocess:
  ```bash
  ct2-transformers-converter \
    --model openai/whisper-large-v3-turbo \
    --output_dir models/whisper-large-v3-turbo \
    --quantization float16 \
    --copy_files tokenizer.json preprocessor_config.json
  ```
  **Critical:** `--copy_files tokenizer.json preprocessor_config.json` is mandatory (without `tokenizer.json` → degraded WER; without `preprocessor_config.json` → wrong mel bin count error)
- [ ] Store converted models in `~/Library/Application Support/CTTranscriber/models/{model-name}/`
- [ ] Download + conversion progress shown in UI (conversion downloads from HuggingFace ~1-3GB)
- [ ] Resume interrupted downloads
- [ ] Model management UI:
  - List downloaded models with sizes
  - Download button for available models
  - Delete downloaded models
  - Set default model
- [ ] Validate model integrity after download (checksum)

### Test Criteria
- [ ] Open model manager, download "tiny" model — progress bar shows, completes
- [ ] Downloaded model appears in list with correct size
- [ ] Delete model — files removed, model disappears from list
- [ ] Interrupt download (quit app), relaunch — download resumes or restarts cleanly
- [ ] Select model in settings — subsequent transcriptions use it

---

## Milestone 7: Audio Transcription Pipeline

**Goal:** Attach audio file, transcribe it, show results in chat.

### Tasks
- [ ] `TranscriptionService` actor:
  - Accepts audio file path + model + settings
  - Runs `transcribe.py` as subprocess
  - Parses JSON output (segments with timestamps)
  - Reports progress via AsyncStream
  - Supports cancellation (kill subprocess)
- [ ] Audio attachment flow:
  - Click attach button → file picker (`.wav`, `.mp3`, `.m4a`, `.flac`, `.ogg`)
  - File copied to app storage
  - Transcription task created automatically
- [ ] Transcription result displayed as formatted message:
  - Timestamps + text segments
  - Collapsible raw transcript
- [ ] Transcription settings from Settings applied (beam, temperature, language)
- [ ] Error handling: unsupported format, model not downloaded, Python env missing

### Test Criteria
- [ ] Attach a 30-second WAV file — transcription completes, text appears in chat
- [ ] Progress bar shows during transcription
- [ ] Cancel transcription mid-way — subprocess killed, partial result shown or discarded
- [ ] Attach MP3 file — works (ffmpeg/format handling)
- [ ] No model downloaded — prompt to download before transcribing
- [ ] Changing beam size in settings affects transcription output

---

## Milestone 8: Background Task Manager

**Goal:** All long-running tasks (downloads, transcriptions) are managed in a unified task system.

### Tasks
- [ ] `TaskManager` actor with persistent task queue (SwiftData):
  - Task states: `pending`, `running`, `paused`, `completed`, `failed`, `cancelled`
  - Task types: `modelDownload`, `transcription`, `pythonSetup`
  - Persist task state — recover after crash/restart
- [ ] Task manager popover/sheet UI:
  - List all tasks with status, progress, type
  - Actions per task: pause/resume, cancel, retry, delete
  - Filter by status
  - Auto-dismiss completed tasks after delay (configurable)
- [ ] Task recovery on app launch:
  - `running` tasks from previous session → restart or mark failed
  - `pending` tasks → resume queue
- [ ] Concurrency control: limit parallel transcriptions (configurable, default 1)
- [ ] Toolbar badge showing active task count

### Test Criteria
- [ ] Start transcription + model download simultaneously — both visible in task manager
- [ ] Pause transcription — task shows paused, can resume
- [ ] Force-quit app during transcription, relaunch — task marked failed, retry available
- [ ] Cancel task — subprocess killed, task marked cancelled
- [ ] Delete completed task — removed from list
- [ ] Task badge in toolbar shows correct count

---

## Milestone 9: macOS Integration

**Goal:** Open audio files with the app from Finder, system-level integration.

### Tasks
- [ ] Register app as handler for audio file types in `Info.plist`:
  - UTTypes: `public.audio`, `public.mp3`, `com.apple.m4a-audio`, `public.wav-audio`, `public.flac-audio`
  - Document types with role Viewer
- [ ] Handle `onOpenURL` / NSDocument open events:
  - Single file: prompt to add to existing conversation or create new
  - Multiple files: batch into one conversation or separate
- [ ] Drag-and-drop onto app icon in Dock
- [ ] Drag-and-drop audio files into chat area
- [ ] Share extension (optional): "Open in CT Transcriber" in Finder share menu

### Test Criteria
- [ ] Right-click audio file in Finder → Open With → CT Transcriber → app opens with file
- [ ] Double-click audio file (if set as default) → opens in app
- [ ] Drag audio file onto Dock icon → app opens, prompts for conversation
- [ ] Drag audio file into chat area → starts transcription
- [ ] Open multiple files at once → handled correctly

---

## Milestone 10: Polish & Distribution

**Goal:** App is ready for distribution as unsigned DMG.

### Tasks
- [ ] App icon (SF Symbols-based or custom design)
- [ ] About window with version, credits, links
- [ ] Menu bar items: standard macOS menus (File, Edit, Window, Help)
- [ ] Keyboard shortcuts: `Cmd+N` new conversation, `Cmd+,` settings, `Cmd+O` open audio
- [ ] First-launch onboarding: quick setup for Python env + API keys
- [ ] Error states: empty states, network errors, missing dependencies
- [ ] Dark mode support (native SwiftUI)
- [ ] DMG creation:
  - Use `create-dmg` or `hdiutil` to create DMG
  - Include background image, Applications shortcut
  - Document Gatekeeper bypass: `xattr -cr /Applications/CTTranscriber.app`
- [ ] README with installation instructions

### Test Criteria
- [ ] DMG opens, drag to Applications works
- [ ] App launches from Applications (after Gatekeeper bypass)
- [ ] All keyboard shortcuts work
- [ ] Dark mode looks correct
- [ ] First launch guides user through setup
- [ ] `Cmd+Q` quits cleanly, no data loss

---

## Milestone 11 (Future): MCP Support

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

## Dependency Graph

```
M0 (Skeleton)
 ├── M1 (Chat UI)
 │    └── M2 (Persistence)
 │         ├── M4 (LLM Integration) ← M3 (Settings)
 │         └── M7 (Transcription) ← M5 (Python Env) ← M6 (Models)
 │              └── M8 (Task Manager)
 ├── M3 (Settings)
 └── M9 (macOS Integration) ← M2, M7
      └── M10 (Polish & DMG) ← all above
           └── M11 (MCP) [future]
```

## Suggested Implementation Order

| Phase | Milestones | Focus |
|-------|-----------|-------|
| **Phase A** | M0 → M1 → M2 → M3 | Core UI + persistence — you see a working chat app |
| **Phase B** | M4 | LLM integration — app becomes useful as a chat client |
| **Phase C** | M5 → M6 → M7 | Transcription pipeline — core differentiator |
| **Phase D** | M8 → M9 | Task management + OS integration — production quality |
| **Phase E** | M10 | Polish + distribution |
| **Phase F** | M11 | Future MCP exploration |

---

## Key Risks

| Risk | Mitigation |
|------|-----------|
| CTranslate2 metal-backend build requires Xcode CLT + conda | Automate in setup script; already proven to build locally (see METAL_QUICKSTART.md) |
| Conda dependency for end users | Automate miniconda install; document clearly in onboarding flow |
| Model conversion downloads are large (1-3 GB for large models) | Start with `whisper-base` (~150 MB) for testing; show size warnings; implement resume |
| `preprocessor_config.json` or `tokenizer.json` missing after conversion | Enforce `--copy_files` flag in conversion script; validate model directory completeness |
| Unsigned app triggers Gatekeeper warnings | Document `xattr -cr` bypass; consider $99/yr Developer ID signing for wider distribution |
| LLM API rate limits / costs | Show token usage estimates; support local models in future |
| Metal shader compilation errors (`msl_strings.h out of sync`) | Run `python3 tools/gen_msl_strings.py` as part of automated build; catch and report clearly |
