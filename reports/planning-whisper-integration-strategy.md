# Planning: Whisper Integration Strategy — Direct CTranslate2 API vs faster-whisper

**Date:** 2026-03-16
**Context:** Deciding whether to use faster-whisper or CTranslate2's native Python API for the transcription pipeline in CT Transcriber macOS app.

---

## Background

CTranslate2 (metal-backend branch, developed locally) exposes two paths for Whisper transcription:

1. **Direct CTranslate2 Python API** — `ctranslate2.models.Whisper` with manual pipeline
2. **faster-whisper** — High-level wrapper around CTranslate2 with one-call `model.transcribe()`

A third option (C++ bridging from Swift, no Python at all) is also evaluated.

---

## Option A: Direct CTranslate2 Python API

Working example exists in `CTranslate2/tests/metal/e2e/test_whisper.py`:

```python
processor = WhisperProcessor.from_pretrained("openai/whisper-base")
features = ctranslate2.StorageView.from_array(processor(...).input_features)
model = ctranslate2.models.Whisper(path, device="mps")
results = model.generate(features, [prefix_tokens])
text = processor.decode(results[0].sequences_ids[0], skip_special_tokens=True)
```

### Pros
- No faster-whisper dependency — one fewer package to install/break
- Full control over the decoding pipeline — customizable behavior
- Slightly less overhead (no Python wrapper layer)
- Working code already exists in the test suite
- Easier to debug — developer wrote CTranslate2 and knows every layer

### Cons
- Must manually implement 30-second audio chunking (already done in test, but needs productionizing)
- **No VAD (Voice Activity Detection)** — silent regions get transcribed as noise/hallucinations
- No temperature fallback/retry logic (faster-whisper tries multiple temperatures on poor segments)
- Must manually build prefix tokens (language detection → token construction)
- Needs `transformers` + `librosa` as dependencies for feature extraction and audio loading
- No `condition_on_previous_text` cross-chunk context
- **Dependency footprint isn't actually much smaller**: still needs `transformers`, `librosa`, `numpy`, and `torch` (for WhisperProcessor)

---

## Option B: faster-whisper (current METAL_QUICKSTART approach)

```python
model = WhisperModel(MODEL_DIR, device="mps", compute_type="float16")
segments, info = model.transcribe(audio, beam_size=5, vad_filter=True)
```

### Pros
- One-call API — `model.transcribe()` handles everything
- **Built-in VAD (Silero VAD)** — dramatically reduces hallucinations on silent segments
- Temperature fallback — retries with higher temperature when decoding fails
- Handles chunking, language detection, timestamps, and segment formatting automatically
- Mature, battle-tested — used by thousands of projects
- Returns proper segments with `start`/`end` timestamps (vs raw token IDs)
- `condition_on_previous_text` for cross-chunk coherence
- Has its own feature extractor — doesn't require `transformers` for mel computation at runtime

### Cons
- Extra dependency layer (faster-whisper + its transitive deps)
- Slightly less control — behavior is baked into faster-whisper's pipeline
- Variance from retry logic can make benchmarking less deterministic (noted in METAL_QUICKSTART)
- If faster-whisper breaks compatibility with the CT2 fork, debugging someone else's code is required

---

## Option C: No Python — C++ Bridging from Swift

### Pros
- Zero Python runtime dependency — fully native app
- Fastest possible startup (no Python interpreter boot)
- Cleanest distribution (no conda/venv management for end users)
- Tightest memory control

### Cons
- Must reimplement the entire Whisper pipeline in Swift/C++:
  - Mel spectrogram computation (~200-300 lines using Accelerate vDSP)
  - Tokenizer (load and use Whisper vocabulary)
  - Decoding loop with beam search
  - Audio chunking and stitching
  - VAD (port Silero or find C++ alternative)
- **Massive engineering effort** — faster-whisper is ~3000 lines of Python logic
- No VAD without porting Silero VAD or finding a C++ alternative
- Known Metal bugs (timestamp state corruption noted in e2e test) would need C++-level workarounds
- Fragile bridging layer (Objective-C++ or C wrapper) to maintain

---

## Comparison Matrix

| Feature | Direct CT2 API | faster-whisper | C++ Bridging |
|---------|---------------|----------------|--------------|
| VAD (silence filtering) | No | Yes (Silero) | Must port |
| Temperature retries | No | Yes | Must implement |
| Audio chunking | Manual | Automatic | Must implement |
| Segment timestamps | Manual token parsing | Built-in | Must implement |
| Language auto-detect | Manual API call | Built-in | Must implement |
| Python dependency | Yes (transformers, librosa, torch) | Yes (faster-whisper) | No |
| Conda/venv required | Yes | Yes | No |
| Implementation effort | Medium (~200 lines wrapper) | Low (~20 lines wrapper) | Very High (~3000+ lines) |
| Debugging ease | High (own codebase) | Medium | High but costly |
| Runtime overhead | Low | Low (+5% Python layer) | Lowest |
| Distribution complexity | Medium | Medium | Low |

---

## Recommendation

**Primary choice: faster-whisper (Option B)** for file-based transcription.

Rationale:
1. **VAD alone is worth the dependency** — without it, users get hallucinated text on silent segments, which is a terrible UX
2. Segment-with-timestamps output maps directly to the chat UI design in the RFC
3. `torch`/`transformers` are already needed for model conversion (`ct2-transformers-converter`), so the runtime dependency delta is small
4. The one-call API makes the `transcribe.py` CLI wrapper trivial to write and maintain

**Future option: Direct CT2 API** for streaming/real-time mic transcription, where controlling the decode loop matters. Could be added as a later milestone.

**Not recommended now: C++ bridging (Option C)** — the engineering effort is disproportionate for a demo tool. Revisit if the app needs to be distributed without any Python dependency (e.g., Mac App Store).

---

## Impact on ROADMAP

- M5 (Python Environment): Use conda `whisper-metal` env with faster-whisper as primary dependency
- M7 (Transcription Pipeline): `transcribe.py` wrapper uses `faster_whisper.WhisperModel.transcribe()`
- Future milestone (optional): Add direct CT2 API path for real-time/streaming transcription
