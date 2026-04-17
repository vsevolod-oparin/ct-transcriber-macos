# MWStreamingTranscriber Rewrite — UFAL Whisper-Streaming Design

**Date:** 2026-03-21
**File:** `metal-faster-whisper/src/MWStreamingTranscriber.mm`
**Status:** Complete. Build passes. Tested with JFK (English) and ds.job (Russian).

---

## What Was Wrong

The original implementation had three fundamental bugs:

### 1. Estimated timestamps (completely unreliable)
`buildTimedWords()` divided the total audio duration evenly across all words. For a 10s buffer with 20 words, each word got 0.5s. This made HypothesisBuffer's time-based filtering unreliable — `last_committed_time` and word start/end times were fiction.

### 2. No segment-boundary buffer trimming
The old code force-committed the hypothesis buffer and trimmed at the last committed time. This broke LocalAgreement continuity. UFAL trims at Whisper segment boundaries (`chunk_completed_segment`), which preserves the hypothesis buffer's internal state.

### 3. Three copy-pasted code paths
`runStreamingOnSamples:`, the mic tap callback, and the engine tap callback all duplicated the same encode/generate/agreement logic with subtle differences. Bugs in one path weren't fixed in others.

---

## What Changed

### UFAL-Faithful Data Structures

**MWHypothesisBuffer** — Faithful port with:
- `commited_in_buffer` — committed words still in audio buffer range
- `buffer` — previous hypothesis (for agreement comparison)
- `new_words` — latest hypothesis
- `insert()` — time offset, `start > last_commited_time - 0.1` filter, n-gram dedup (1-5)
- `flush()` — LocalAgreement via exact word text prefix match
- `pop_commited()` — removes front entries after buffer trim
- `complete()` — returns uncommitted buffer
- `force_commit()` — for silence/end-of-stream

**MWProcessorState** — Holds UFAL OnlineASRProcessor state:
- `audio_buffer` — growing, trimmed at segment boundaries
- `transcript_buffer` — HypothesisBuffer
- `committed` — all committed words since start
- `buffer_time_offset` — time offset of audio_buffer[0]
- `buildPrompt()` — last 200 chars of committed text before buffer_time_offset
- `chunkAt()` — trim audio and hypothesis at absolute time
- `chunkCompletedSegment()` — find segment end for trimming

### Timestamp Tokens for Real Segment Boundaries

Changed from `withoutTimestamps: YES` to `withoutTimestamps: NO`. Whisper now generates timestamp tokens (`<|0.00|>`, `<|2.40|>`, etc.) which `splitSegmentsByTimestamps:` parses into segments with accurate start/end times.

Always pad mel to 3000 frames (`kMWDefaultChunkFrames`) — required for proper timestamp token generation even with shorter audio buffers.

### Per-Segment Word Timing

Instead of dividing total audio duration across all words, we now:
1. Get accurate segment boundaries from timestamp tokens
2. Split segment text into words
3. Distribute timing proportionally by character count within each segment

This gives much more accurate word timing, especially for segments of different lengths within the same buffer.

### Unified Core Algorithm

Single `processIter:tokenizer:handler:stopped:` method shared by all three entry points:
1. Silence check → force-commit + reset
2. Mel extraction + pad to 3000 frames
3. Encode
4. Build prompt from committed text
5. Generate WITH timestamps
6. Split segments by timestamps
7. Extract timed words per segment
8. HypothesisBuffer insert + flush (LocalAgreement)
9. Emit confirmed text
10. Emit hypothesis
11. Buffer trimming at segment boundary if > 15s

### Audio Flow (Mic Streaming)

Simplified: tap callback accumulates audio in a tap-thread-local buffer, dispatches chunks to the serial decode queue where `procState.audio_buffer` grows and gets trimmed. All state mutation on the decode queue — no cross-thread coordination flags.

---

## Test Results

### JFK (English, ~11s)
```
CONFIRMED: " And"
CONFIRMED: " so, my fellow Americans, ask"
CONFIRMED: " not what your country"
CONFIRMED: " can do for you."
CONFIRMED: " ask what you can do for your country."
```
5 confirmed emissions, 8 hypothesis emissions. Full text accurate.

### ds.job (Russian, 18:20-18:40, 20s)
```
CONFIRMED: " Вот я"
CONFIRMED: " знаю, что некоторые"
CONFIRMED: " компании в России"
CONFIRMED: " хотят сделать"
CONFIRMED: " этот"
CONFIRMED: " self-driving bank."
CONFIRMED: " Я вот не знаю, честно говоря, кому бы и где бы я больше опасался."
CONFIRMED: " опасался салфаванг bank"
CONFIRMED: " Звучит страшновато, да."
```
9 confirmed emissions, 17 hypothesis emissions. Buffer trimming triggered at 16s (dropped to 5s), no missed fragments. Segment transition visible.

### Performance (whisper-large-v3, M4)
- Encode: ~1.1s constant (always 3000-frame mel)
- Generate: 0.5s (2s audio) → 2.6s (16s audio)
- Total per iteration: 1.6s (2s audio) → 3.8s (16s audio)
- RTF: ~0.24 at 16s (well within real-time at 1s update interval for typical buffer sizes)

---

## File Stats

- Lines: 1219 (down from 1443)
- MWStreamingTranscriber class: ~840 lines
- Key structures (MWHypothesisBuffer + MWProcessorState): ~190 lines

---

## Post-Rewrite Optimization (Session 2)

### Profiling Results (whisper-large-v3 on M4)

**Memory:**
- Model load: 3.6 GB (expected for large-v3, no leak)
- Streaming malloc: 67 MB (modest, no leak)
- Peak during streaming: +149 MB over model baseline
- Conclusion: **no memory issue**. The 15GB the user observed was likely from running multiple models or test suites concurrently.

**Bottleneck: 3000-frame mel padding.** Every audio buffer (even 2s = 200 frames) was padded to 3000 frames (30s equivalent) for timestamp token generation. This meant every encode took ~1.0s regardless of actual audio length, wasting 83-93% of encoder compute.

### Fix: Variable-length mel encoding

Removed forced 3000-frame padding. Encode actual frame count (only trim if > 3000). Switched to `withoutTimestamps: YES` since timestamp tokens require padded mel. Buffer trimming uses time-based approach instead of segment boundaries.

### Benchmark: review.wav (Russian natural speech, ~33s)

| Metric | BEFORE (padded) | AFTER (variable) | Speedup |
|--------|-----------------|-------------------|---------|
| Encode @ 2s audio | 1057ms | 89ms | **11.9x** |
| Encode @ 10s audio | 1041ms | 265ms | **3.9x** |
| Encode @ 16s audio | 1017ms | 454ms | **2.2x** |
| Total streaming time | 71,358ms | 44,588ms | **1.6x** |
| Total per-iter @ 2s | 1,617ms | 356ms | **4.5x** |
| Total per-iter @ 10s | 2,564ms | 1,303ms | **2.0x** |

### Additional fixes in Session 2

1. **Silero VAD integration** — replaced amplitude-based silence detection (threshold 0.01) with Silero VAD v6 via `speechProbabilities:`. Completely eliminates hallucinations during silence. Lazy-initialized from model path.

2. **Normalized word comparison** — `flush()` now uses `wordsMatchNormalized()` which strips trailing punctuation and lowercases for comparison. Fixes drops where Whisper adds/removes punctuation between decodes ("5" vs "5,").

3. **Token limit** — 5 tokens/second cap prevents Whisper from over-generating beyond actual speech content.

## Known Limitations

1. **Word dropping at LocalAgreement boundaries** — when Whisper shifts word positions between consecutive decodes, the prefix-match breaks. Most visible with rapid enumeration (counting 1-70). Less noticeable with natural speech.
2. **Proportional word timing** — without timestamp tokens, word timing is estimated proportionally across the audio duration. Less accurate than per-segment timing but sufficient for LocalAgreement.
3. **Large model performance** — at 16s buffer, total iteration time is ~2.1s. With 1s update interval, iterations queue slightly but catch up after buffer trim.
