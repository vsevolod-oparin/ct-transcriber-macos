# Research: Flash Attention Benchmark & Timestamps Bug Investigation

**Date:** 2026-03-17
**Audio:** 60s MP3 (Russian podcast), whisper-large-v3-turbo, Metal GPU (mps)

---

## Flash Attention Benchmark

| Configuration | Time (s) | RTF | vs Baseline |
|--------------|----------|-----|-------------|
| flash=OFF, timestamps=ON | **17.18** | 0.286 | baseline |
| flash=OFF, timestamps=OFF | **13.37** | 0.223 | **22% faster** |
| flash=ON, timestamps=ON | **17.62** | 0.294 | 3% slower |
| flash=ON, timestamps=OFF | **18.12** | 0.302 | 5% slower |

### Key Findings

1. **Flash attention does NOT improve speed** on this workload — it's slightly slower (3-5%). This may be because:
   - The fused SDPA decode kernel overhead isn't amortized on short sequences (Whisper's 30s chunks)
   - The kernel might not be fully optimized for the Whisper architecture's head dimensions
   - Metal's MPS GEMM path may already be efficient enough for these sizes

2. **Skipping timestamps gives a solid 22% speedup** — this is the real performance win. The decoder generates fewer tokens (no timestamp tokens) and doesn't do seek retries.

3. **Flash + skip timestamps is slower than just skip timestamps** — suggesting flash attention adds overhead that isn't offset by any speedup.

### Recommendation

- **Flash attention**: default OFF. It doesn't help and slightly hurts.
- **Skip timestamps**: advertise as the speed option (22% faster).

---

## Timestamps State Corruption Investigation

**Test:** Direct CTranslate2 API (bypassing faster-whisper), Metal GPU.

1. Generate with 4-token prefix (no timestamps) → OK, 4 output tokens
2. Generate with 3-token prefix (timestamps) → OK, 99 output tokens
3. Generate with 4-token prefix again → **OK, matches Test 1**

### Finding

**No state corruption detected** with the current CTranslate2 metal-backend build (4.7.1, updated wheel). The bug noted in the e2e test (`test_whisper.py`) may have been fixed in a recent CTranslate2 update, or it may only manifest under specific conditions (batched inference, specific model sizes, or longer sequences).

### Recommendation

- The timestamps mode appears stable with the current build
- Continue monitoring — if users report garbled output after timestamps mode, revisit
- The e2e test in CTranslate2 repo should be re-run to confirm the fix
