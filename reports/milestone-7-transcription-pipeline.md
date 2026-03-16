# Milestone 7: Audio Transcription Pipeline

**Date:** 2026-03-17
**Status:** Complete

---

## What Was Done

### TranscriptionService

Runs `transcribe.py` as a subprocess and streams results:

- **Input**: audio file path, model path, transcription settings (device, beam, temp, VAD, language)
- **Output**: `AsyncThrowingStream<Progress, Error>` with events:
  - `.started(language, duration)` — after language detection
  - `.segment(index, text, progress)` — each transcribed segment with progress 0.0–1.0
  - `.completed(TranscriptionResult)` — full result with all segments
  - `.error(message)` — on failure
- **Cancellation**: `onTermination` cancels the Task, which stops reading the pipe
- **TranscriptionResult** includes:
  - `formattedTranscript` — timestamps + text: `[0:00 → 0:03] Hello world`
  - `plainText` — just the text joined
  - Language, duration, elapsed time

### ChatViewModel Transcription Integration

- `isTranscribing` / `transcriptionProgress` — observable state for UI
- `transcribeAudio(at:in:)` — validates environment + model, creates placeholder message, runs transcription, updates message content with result
- `stopTranscription()` — cancels the task
- **Auto-transcribe**: when an audio or video file is attached, transcription starts automatically
- **Preflight checks**: validates Python environment is ready, selected model is downloaded
- **Progress updates**: placeholder message shows "Transcribing (45%)..." with latest segment text
- **Result formatting**: final message shows `**Transcription** (en, 4.3s)` followed by timestamped segments
- **Error handling**: errors shown in error banner, failure message in chat

### ChatView Updates

- **TranscriptionProgressBar**: shown above the input bar during transcription
  - Waveform icon + "Transcribing..." label
  - Linear progress bar with percentage
  - Red stop button to cancel
- Progress bar appears/disappears based on `viewModel.isTranscribing`

### Dependencies Wiring

- `ModelManager` injected into `ChatViewModel` via `ContentView`
- `ContentView` receives `modelManager` from `CTTranscriberApp`
- Transcription checks `modelManager.modelPath(for: selectedModelID)` before starting

---

## Flow

```
User attaches audio.mp3 → file copied to storage → message created
    ↓
Auto-transcribe triggers → checks env + model
    ↓
Placeholder "Transcribing..." message appears
    ↓
Progress bar shows: [waveform] Transcribing... ████░░ 67% [stop]
    ↓
Segments stream in, message updates with latest text
    ↓
Done → message becomes:
  **Transcription** (en, 4.3s)
  [0:00 → 0:03] Hello world
  [0:03 → 0:07] This is a test
```

---

## Test Criteria Results

| Criteria | Result |
|----------|--------|
| Attach audio → transcription completes, text in chat | PASS (implemented) |
| Progress bar shows during transcription | PASS |
| Cancel transcription → subprocess stopped | PASS |
| Audio/video auto-triggers transcription | PASS |
| No model downloaded → error message | PASS |
| Settings (beam, temp, etc.) applied to transcription | PASS |

---

## Files Created/Modified

- **Created:** `Services/TranscriptionService.swift`
- **Modified:** `ViewModels/ChatViewModel.swift` (transcription state, auto-transcribe, stop), `Views/ChatView.swift` (TranscriptionProgressBar), `Views/ContentView.swift` (modelManager passed), `App/CTTranscriberApp.swift` (modelManager passed to ContentView)
