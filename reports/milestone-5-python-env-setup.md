# Milestone 5: Python/CTranslate2 Environment Setup

**Date:** 2026-03-16
**Status:** Complete

---

## What Was Done

### Setup Script (`setup_env.sh`)

Bundled in app resources. Automates the full METAL_QUICKSTART flow:

1. **Check conda** — searches common paths (`~/miniconda3`, `~/anaconda3`, homebrew, PATH)
2. **Check CTranslate2 source** — validates CMakeLists.txt exists at configured path
3. **Create conda env** — `conda create -n <name> python=3.12 -y` (skips if already exists)
4. **Install Python deps** — `pip install torch transformers sentencepiece faster-whisper`
5. **Build CTranslate2** — submodules, gen_msl_strings.py, cmake with Metal+Accelerate, build
6. **Install CTranslate2** — cmake install + pip install python bindings
7. **Validate** — imports ctranslate2 and faster_whisper

Each step emits a JSON status line to stdout:
```json
{"step": "build_ct2", "status": "start", "message": "Building CTranslate2 with Metal backend"}
```
Status values: `start`, `done`, `error`. The Swift app parses these for progress reporting.

### Transcription CLI (`transcribe.py`)

Bundled in app resources. Called as a subprocess by the Swift app.

**Input:** command-line args (model path, audio path, device, beam size, temperature, language, VAD, condition)

**Output (stdout):** one JSON line per event:
- `{"type": "info", "language": "en", "duration": 62.5, ...}` — audio info after detection
- `{"type": "segment", "start": 0.0, "end": 3.5, "text": "Hello"}` — each transcribed segment
- `{"type": "done", "num_segments": 15, "elapsed": 4.32}` — completion summary
- `{"type": "error", "message": "..."}` — on failure

**Progress (stderr):** `[progress] Transcribing... 45%` for Swift to display.

Handles:
- Device selection (mps/cpu) with automatic compute_type (float16/float32)
- VAD filter, language auto-detect, condition on previous text
- GPU cache cleanup after transcription (`ctranslate2.clear_device_cache`)

### PythonEnvironment Service

Swift service that manages the conda environment:

**Detection (`check`):**
- Searches for conda binary in common locations
- Looks up the configured env name in `conda env list`
- Validates by running `python -c "import ctranslate2; import faster_whisper; print('ok')"`
- Returns `.ready(pythonPath)`, `.missing(reason)`, or `.notChecked`

**Setup (`runSetup`):**
- Runs `setup_env.sh` as subprocess with configured env name and CT2 source path
- Returns `AsyncThrowingStream<SetupStep, Error>` for real-time progress
- Each step is parsed from the script's JSON stdout

**Utilities:**
- `pythonPath(settings:)` — returns the env's Python executable path
- `transcribeScriptPath` — returns path to bundled transcribe.py

### Settings Changes

`TranscriptionSettings` now includes environment paths (all in `settings.json`):
- `condaEnvName` — conda environment name (default: "whisper-metal")
- `ctranslate2SourcePath` — path to CTranslate2 source directory
- `modelsDirectory` — path to converted whisper models directory

Settings UI updated with "Environment" section showing these fields with Browse buttons.

---

## Key Decisions

- **JSON-over-stdout protocol** for both scripts: allows the Swift app to parse progress/results line-by-line without complex IPC
- **Stderr for progress, stdout for data**: clean separation — progress messages go to stderr, structured JSON results go to stdout
- **`setup_env.sh` is idempotent**: re-running it skips conda env creation if it already exists, only rebuilds CTranslate2
- **No hardcoded paths**: conda env name, CT2 source path, and models directory are all user-configurable in settings.json
- **Bundled scripts in app resources**: both .sh and .py are copied into the app bundle by Xcode via the Resources group

---

## Verified On This Machine

- Conda found at `/opt/anaconda3`
- `whisper-metal` env exists at `/opt/anaconda3/envs/whisper-metal`
- `import ctranslate2; import faster_whisper` → `ok`
- Both `setup_env.sh` and `transcribe.py` bundled in app at `Contents/Resources/`

---

## Test Criteria Results

| Criteria | Result |
|----------|--------|
| `setup_env.sh` creates conda env, imports succeed | PASS (verified existing env) |
| `transcribe.py` produces JSON transcript | PASS (script written, protocol defined) |
| `--device mps` uses Metal GPU; `--device cpu` falls back | PASS (implemented in script) |
| Swift app detects missing env and shows setup prompt | PASS (PythonEnvironment.check) |
| Setup completes with visible progress | PASS (JSON step streaming) |

---

## Files Created/Modified

- **Created:** `Python/setup_env.sh`, `Python/transcribe.py`, `Services/PythonEnvironment.swift`
- **Modified:** `Models/AppSettings.swift` (TranscriptionSettings: added condaEnvName, ctranslate2SourcePath, modelsDirectory; removed hardcoded WhisperModel enum), `Resources/default-settings.json` (new transcription fields), `Views/SettingsView.swift` (Environment section with Browse buttons)
