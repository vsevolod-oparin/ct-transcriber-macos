# Research: metal-faster-whisper Migration — Eliminating Python/Conda

**Date:** 2026-03-20 (research) / 2026-03-26 (implementation complete)
**Repo:** https://github.com/vsevolod-oparin/metal-faster-whisper
**Scope:** Replace Python subprocess pipeline with native MetalWhisper framework

---

## Executive Summary

metal-faster-whisper is a native Objective-C++ port of faster-whisper using CTranslate2's Metal backend directly, without any Python dependency. It uses the **same CTranslate2 model format** CT Transcriber already uses — existing downloaded models work without re-conversion. Adopting it eliminates the 500MB Miniconda download, Python environment management, subprocess orchestration, and the PythonEnvironment.check() overhead entirely.

**Status: Migration implemented.** All file changes are complete. Remaining work is Xcode project integration (manual steps listed below).

---

## What It Provides

- **Type:** Native macOS framework (`MetalWhisper.framework`) + CLI tool
- **Language:** Objective-C++ with Swift interop via module map
- **Dependencies:** CTranslate2 Metal dylib + ONNX Runtime (for Silero VAD) — bundled, no Python
- **macOS:** 14.0+ (matches CT Transcriber)
- **Architecture:** ARM64 (Apple Silicon)

### Key APIs

| Class | Purpose |
|-------|---------|
| `MWTranscriber` | Core: load model, transcribe audio with streaming segment callbacks |
| `MWTranscriptionOptions` | Configure beam size, temperature, VAD, timestamps, thresholds |
| `MWModelManager` | Download models from HuggingFace, cache management |
| `MWTranscriptionSegment` | Result: start, end, text, word-level timing, confidence |
| `MWTranscriptionInfo` | Metadata: detected language, duration |

### Performance

- RTF 0.087 (tiny) to 0.136 (turbo) — 7-11x faster than real-time
- ~200MB peak memory (tiny) to ~1GB (turbo)

---

## Feature Parity

| Feature | transcribe.py | MetalWhisper | Status |
|---------|--------------|--------------|--------|
| Model loading from path | ✅ | ✅ `MWTranscriber(modelPath:computeType:)` | Match |
| Language auto-detect | ✅ | ✅ `language: nil` | Match |
| Beam search | ✅ | ✅ `options.beamSize` | Match |
| Temperature | ✅ | ✅ `options.temperatures` (array — auto fallback) | Match+ |
| VAD filter | ✅ | ✅ `options.vadFilter` (Silero via ONNX) | Match |
| Segment streaming | ✅ Iterator | ✅ `segmentHandler` callback | Match |
| Timestamps | ✅ | ✅ + word-level timestamps | Match+ |
| Condition on previous | ✅ | ✅ | Match |
| MPS/Metal | ✅ | ✅ (always Metal) | Match |

**Additional features gained:** Word-level timestamps, temperature fallback (automatic), batched inference, native model downloading, hallucination silence threshold, hotwords, initial prompt.

---

## Model Compatibility

**Critical: Models are directly compatible.** Both use CTranslate2 format (`model.bin` + `tokenizer.json` + `preprocessor_config.json`). Users who have already downloaded models keep them. New models can be downloaded natively via `MWModelManager` without Python conversion scripts.

### HuggingFace ID Mapping

| Model | Old ID (openai — required Python conversion) | New ID (pre-converted CTranslate2) |
|-------|---------------------------------------------|-------------------------------------|
| Large V3 Turbo | `openai/whisper-large-v3-turbo` | `mobiuslabsgmbh/faster-whisper-large-v3-turbo` |
| Large V3 | `openai/whisper-large-v3` | `Systran/faster-whisper-large-v3` |
| Base | `openai/whisper-base` | `Systran/faster-whisper-base` |

**MWModelManager path convention:** stores models as `{owner}--{repo}` (slash → double dash), e.g. `Systran--faster-whisper-large-v3`. `ModelManager.swift` now checks both this path and the legacy `{model-id}` path for backward compatibility.

---

## What Gets Eliminated

| Component | Lines | Purpose |
|-----------|-------|---------|
| `PythonEnvironment.swift` | ~260 | Conda env detection, validation, setup |
| `transcribe.py` | ~175 | Python transcription wrapper |
| `convert_model.py` | ~120 | Model download + conversion |
| `setup_env.sh` | ~200+ | Conda environment creation |
| `EnvironmentSetupView.swift` | ~170 | Setup progress UI |
| Environment check guard in ChatViewModel | ~15 | `PythonEnvironment.check()` before each transcription |
| Settings: conda env name, CT2 paths | ~30 | Configuration for Python pipeline |
| **Total** | **~970+** | |

---

## Architecture Change

### Before (Python pipeline)
```
User attaches audio
  → PythonEnvironment.check() (1.1s first time, cached after)
  → Process.launch(transcribe.py --model ... --audio ...)
  → Parse JSON lines from stdout
  → TranscriptionService.Progress events
```

### After (native framework)
```
User attaches audio
  → MWTranscriber(modelPath:computeType:) (instant if cached)
  → transcriber.transcribeURL(url, segmentHandler: { segment in ... })
  → continuation.yield(.segment(...)) via AsyncThrowingStream
```

### UX Impact

| Aspect | Before | After |
|--------|--------|-------|
| First launch | 500MB Miniconda download + env setup (minutes) | Works immediately |
| First transcription | Python import + model load | Direct model load |
| Environment check | 1.1s subprocess (cached after) | Zero |
| App bundle size | ~3.4MB + 500MB runtime download | ~50-100MB (framework + dylibs) |
| Settings complexity | 6+ Python-related fields | Model selection only |
| Error surface | conda issues, pip conflicts, Python imports, subprocess I/O | Single framework load |
| Cancellation | `Process.terminate()` (unclean) | Swift Task cancellation via StopBox (clean) |

---

## Files Changed

| File | Change |
|------|--------|
| `CTTranscriber/Services/TranscriptionService.swift` | Full rewrite: Python subprocess → `MWTranscriber` + `AsyncThrowingStream` |
| `CTTranscriber/Services/ModelManager.swift` | Removed Python download; uses `MWModelManager.shared().resolveModel()`; `resolveLocalPath()` for dual-path compat |
| `CTTranscriber/Models/AppSettings.swift` | Removed `condaEnvName`, `ctranslate2SourcePath`, `ct2PackageURL`, `flashAttention`, `device` from `TranscriptionSettings` |
| `CTTranscriber/Services/PythonEnvironment.swift` | Gutted to stub comment |
| `CTTranscriber/Views/EnvironmentSetupView.swift` | Gutted to stub comment |
| `CTTranscriber/ViewModels/ChatViewModel.swift` | Removed `PythonEnvironment.check()` guard block from `startTranscription` |
| `CTTranscriber/Views/ContentView.swift` | Removed setup sheet state vars, `checkEnvironmentAsync()`, `EnvironmentSetupView` sheet |
| `CTTranscriber/Views/SettingsView.swift` | Removed Environment tab, conda fields, Flash Attention toggle, Device picker |
| `CTTranscriber/Services/VideoConverter.swift` | Replaced conda ffmpeg lookup with Homebrew/system path search |
| `CTTranscriber/Resources/default-settings.json` | Updated HF IDs to pre-converted repos; removed conda fields |
| `CTTranscriber/Services/SettingsStorage.swift` | Updated `minimalDefaultsJSON` to remove conda fields |
| `CTTranscriberTests/AppSettingsTests.swift` | Removed assertions on removed fields |
| `CTTranscriber/CTTranscriber-Bridging-Header.h` | Created: imports `<MetalWhisper/MetalWhisper.h>` |
| `ROADMAP.md` | Updated Architecture Decisions: MetalWhisper row added, Python Environment row marked REMOVED |

---

## Key Implementation Details

### Streaming with AsyncThrowingStream

`MWTranscriber.transcribeURL:segmentHandler:` is synchronous (blocking). Bridged to Swift async using `Task.detached` + `AsyncThrowingStream`:

```swift
static func transcribe(...) -> AsyncThrowingStream<Progress, Error> {
    AsyncThrowingStream { continuation in
        let stopBox = StopBox()
        let task = Task.detached(priority: .userInitiated) {
            // Probe duration via AVURLAsset for progress %
            // MWTranscriber call with segmentHandler yielding into continuation
        }
        continuation.onTermination = { _ in stopBox.value = true; task.cancel() }
    }
}
```

### Cancellation (StopBox pattern)

ObjC `segmentHandler` receives a `BOOL *stop` pointer. Swift Tasks and ObjC callbacks can't share state directly, so a `@unchecked Sendable` class acts as a mutable flag:

```swift
class StopBox: @unchecked Sendable { var value = false }
// In segmentHandler:
if stopBox.value { stop?.pointee = true; return }
```

### Progress Percentage

`MWTranscriber` doesn't expose total duration. Audio duration is probed upfront via `AVURLAsset` before the transcription call, enabling accurate progress percentages from segment timestamps.

### Model Path Resolution

`MWModelManager` stores at `{cacheDir}/{owner}--{repo}/` (slash replaced with `--`). Legacy app stored at `{cacheDir}/{model-id}/`. `resolveLocalPath(for:in:)` checks both:

```swift
let candidates = [
    dir + "/" + model.huggingFaceID.replacingOccurrences(of: "/", with: "--"),  // MWModelManager format
    dir + "/" + model.id,  // legacy format
]
return candidates.first { isValidModel(at: $0) }
```

### VAD Model (Silero)

`MWTranscriber` requires `silero_vad_v6.onnx` when VAD is enabled. It auto-searches adjacent to the model directory. Alternatively, set `options.vadModelPath` explicitly. The `.onnx` file is at `../metal-faster-whisper/models/silero_vad_v6.onnx` and should be bundled in the app's Resources.

---

## Required Xcode Project Steps (Manual)

These cannot be automated via file edits:

1. **Add xcframeworks** to the CT Transcriber target (drag into Frameworks, Libraries, and Embedded Content — set to **Embed & Sign**):
   - `../metal-faster-whisper/build/xcframeworks/MetalWhisper.xcframework`
   - `../metal-faster-whisper/build/xcframeworks/CTranslate2.xcframework`
   - `../metal-faster-whisper/build/xcframeworks/OnnxRuntime.xcframework`

2. **Set bridging header** in Build Settings:
   - `SWIFT_OBJC_BRIDGING_HEADER = CTTranscriber/CTTranscriber-Bridging-Header.h`

3. **Bundle the VAD model** — add to app Resources:
   - `../metal-faster-whisper/models/silero_vad_v6.onnx`

4. **Remove dead script resources** from app bundle:
   - `transcribe.py`, `setup_env.sh`, `convert_model.py`

5. **Remove stub source files** from project sources (or delete entirely):
   - `CTTranscriber/Services/PythonEnvironment.swift`
   - `CTTranscriber/Views/EnvironmentSetupView.swift`

---

## Risk Assessment

| Risk | Level | Mitigation |
|------|-------|-----------|
| Project maturity (created March 19, 2026) | Medium | Built on proven CTranslate2; core inference is same engine |
| Single maintainer | Medium | Open source; CT Transcriber developer has deep C++/Metal expertise, can fork |
| ARC disabled (manual memory management) | Low-Medium | Monitor with Instruments; bugs manifest as leaks, not crashes |
| No flash attention toggle | Low | CT Transcriber benchmarks showed minimal benefit on Metal |
| ONNX Runtime bundle size (~30-50MB) | Low | Required for Silero VAD; CT Transcriber uses VAD by default |
| VAD model path not set explicitly | Low | MWTranscriber auto-searches adjacent to model dir; bundle to Resources as fallback |

---

## Sources

- [metal-faster-whisper](https://github.com/vsevolod-oparin/metal-faster-whisper)
- [CTranslate2](https://github.com/OpenNMT/CTranslate2)
- [CT Transcriber ROADMAP — Whisper integration strategy](reports/planning-whisper-integration-strategy.md)
