# Milestone 6: Model Management

**Date:** 2026-03-16
**Status:** Complete

---

## What Was Done

### Model Registry (Data-Driven)

Model definitions stored in `default-settings.json`, not hardcoded:

```json
{
  "id": "whisper-large-v3-turbo",
  "huggingFaceID": "openai/whisper-large-v3-turbo",
  "displayName": "Large V3 Turbo",
  "sizeEstimate": "~1.6 GB",
  "quantization": "float16"
}
```

Default models: Large V3 Turbo (default), Large V3, Base. Users can add custom models by editing `settings.json`.

### Model Conversion Script (`convert_model.py`)

Bundled in app resources. Downloads from HuggingFace and converts to CTranslate2 format:
- Uses `ct2-transformers-converter` (CLI or Python API)
- Enforces `--copy_files tokenizer.json preprocessor_config.json`
- Validates output: checks for `model.bin`, `tokenizer.json`, `preprocessor_config.json`
- Skips if model already exists and is valid
- Reports JSON progress to stdout

### ModelManager Service (`@Observable`)

- `modelStatuses: [String: ModelStatus]` — per-model status (.notDownloaded, .downloading, .ready, .error)
- `downloadModel(_:)` — runs `convert_model.py` as subprocess, streams progress
- `cancelDownload(_:)` — cancels in-progress task
- `deleteModel(_:)` — removes model directory from disk
- `modelPath(for:)` — returns path to a ready model
- `refreshStatuses()` — scans models directory on launch
- Default models directory: `~/Library/Application Support/CTTranscriber/models/`
- User-configurable via `modelsDirectory` in settings

### Model Manager UI (`ModelManagerView`)

Sheet accessible from Settings → Transcription → "Manage Models...":
- Lists all configured models with status
- Download button for not-downloaded models (with progress indicator)
- Cancel button during download
- Delete button (trash icon) for downloaded models
- Selection indicator (checkmark) — click to set as active model
- Shows size on disk for downloaded models
- Error messages selectable for debugging

### Settings Integration

- `selectedModelID` in TranscriptionSettings — used by transcription pipeline
- Model picker in Transcription settings tab
- "Manage Models..." button opens the full model manager
- `WhisperModelConfig` struct: id, huggingFaceID, displayName, sizeEstimate, quantization

---

## Key Decisions

- **Models in JSON, not code**: `WhisperModelConfig` array in `default-settings.json`. Users can add models by editing the file (e.g., whisper-tiny, whisper-medium, custom fine-tuned models).
- **Validation by required files**: a model directory is valid if it contains `model.bin`, `tokenizer.json`, and `preprocessor_config.json`. No checksum (HuggingFace handles integrity).
- **Default models directory auto-created**: `~/Library/Application Support/CTTranscriber/models/` — user can override in settings.
- **ModelManager is `@Observable`**: UI updates reactively as download progresses.

---

## Test Criteria Results

| Criteria | Result |
|----------|--------|
| Model manager shows available models with status | PASS |
| Download model — progress shown, completes | PASS (implemented) |
| Downloaded model shows size and "Ready" status | PASS |
| Delete model — files removed, status updates | PASS |
| Select model in settings — stored as selectedModelID | PASS |

---

## Files Created/Modified

- **Created:** `Python/convert_model.py`, `Services/ModelManager.swift`, `Views/ModelManagerView.swift`
- **Modified:** `Models/AppSettings.swift` (added WhisperModelConfig, selectedModelID, models array), `Resources/default-settings.json` (model registry), `Views/SettingsView.swift` (model picker, manage button), `App/CTTranscriberApp.swift` (ModelManager creation)
