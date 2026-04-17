# MPS Buffer Dimension Mismatch Bug — Root Cause Analysis

## Bug Summary

When the Whisper encoder runs with 3000 frames (beam search, beamSize=5) followed by a different frame count (e.g., 200 frames, greedy beamSize=1), the MPS backend produces all-zero logits (token ID 0 = `!`). Using consistent 3000-frame dimensions works fine. `synchronize_stream(Device::MPS)` after beam search does not fix it.

## Investigation Scope

Examined all Metal backend files in `/Users/smileijp/projects/branch/CTranslate2/src/metal/`:
- `allocator.mm` — MetalAllocator with power-of-2 bucket caching
- `utils.mm` — thread-local command buffer/queue infrastructure
- `utils.h` — CT2_COMMIT_AND_WAIT macro, API declarations
- `primitives_gemm.mm` — GEMM dispatch (MPS, f16 promotion, f16 direct, BF16, INT8)
- `primitives_memory.mm` — memory copy/fill primitives
- `ops_conv1d.mm` — Conv1D (im2col + GEMM)
- `ops_sdpa.mm` — Scaled Dot-Product Attention

Also examined model/layer code:
- `src/layers/whisper.cc` — WhisperEncoder, WhisperDecoder
- `src/models/whisper.cc` — WhisperReplica::generate(), encode()
- `src/layers/decoder.cc` — state replication for beam search
- `src/layers/transformer.cc` — decoder state management, `replicate_state`
- `include/ctranslate2/replica_pool.h` — idle() callback
- `src/devices.cc` — synchronize_stream
- `src/thread_pool.cc` — Worker::run() loop

## Findings

### What is NOT the root cause

1. **MetalAllocator caching** (`allocator.mm`): The power-of-2 bucket allocator is dimension-agnostic. It caches MTLBuffers by bucket size, not by tensor shape. When a smaller tensor is allocated from a larger bucket, the extra bytes are unused garbage but the tensor's `requested_size` correctly tracks the live range. The pointer cache invalidation in `free()` is thorough (scans all entries overlapping the freed range). The allocator is not the source.

2. **MPSMatrixMultiplication cache** (`primitives_gemm.mm:560-649`): The GEMM cache keys include `(transpose_a, transpose_b, m, n, k, alpha, beta, batch_size)`. Different dimensions produce different cache keys, so a stale MPSMatrixMultiplication object is never reused for wrong dimensions. The SDPA GEMM cache (`ops_sdpa.mm:140`) uses the same pattern. These caches are correct.

3. **`idle()` and synchronize_stream**: The `ReplicaWorker::idle()` override calls `synchronize_stream(Device::MPS)`, which calls `CT2_COMMIT_AND_WAIT()`, which commits the command buffer and waits. This fires between jobs (between separate `generate()` calls). GPU work IS properly flushed between calls.

4. **Decoder state management**: `TransformerDecoder::replicate_state()` returns `false` for names starting with "memory" — the encoder output is NOT replicated for beam search (since all beams share the same encoder output). The "memory" state is erased after step 0. The decoder gets a fresh `initial_state()` for each `generate()` call. No stale decoder state persists across calls.

5. **Encoder layer code** (`src/layers/whisper.cc`): `WhisperEncoder::operator()` is stateless — it creates local `StorageView` temporaries, runs conv1d/transpose/position_embedding/transformer layers, and writes to the output. No caching of intermediates across calls.

### Root Cause: The `F16TempCache` / `SdpaF16TempCache` reuses oversized buffers without zeroing

**Primary suspect: `primitives_gemm.mm:980-993` and `ops_sdpa.mm:196-214`**

```cpp
struct F16TempCache {
  id<MTLBuffer> buf[3] = {nil, nil, nil};   // A, B, C temps
  NSUInteger    cap[3] = {0, 0, 0};

  id<MTLBuffer> get(int idx, NSUInteger bytes) {
    if (bytes <= cap[idx]) return buf[idx];  // REUSE: larger buffer returned for smaller request
    if (buf[idx]) [buf[idx] release];
    buf[idx] = alloc_temp_buffer(bytes);
    cap[idx] = [buf[idx] length];
    return buf[idx];
  }
};

static thread_local F16TempCache _f16_temp_cache;
```

**The mechanism:**

1. **First call** (beam search, beamSize=5, 3000 frames → 1500 encoder time steps): The encoder runs with m=1500. The f16 promoted GEMM path (`dispatch_f16_promoted_gemm`, line 1006) requests temp buffers sized for m=1500. The cache allocates large buffers.

2. **Second call** (greedy, beamSize=1, 200 frames → 100 encoder time steps): The encoder runs with m=100. `_f16_temp_cache.get()` returns the SAME large buffer (1500-row capacity) for the 100-row request. The buffer contains stale data from the previous beam search computation in rows 100-1499.

3. **The promoted GEMM pipeline** (`dispatch_f16_promoted_gemm`, lines 1046-1069):
   - Step 1: `encode_half_to_float32` converts A[rows_a × cols_a] and B[rows_b × cols_b] to float32 in `tmp_a` and `tmp_b`. This only writes the actual rows needed — **the remaining rows retain stale float32 values from the previous call**.
   - Step 2: `dispatch_mps_gemm_buf` creates an `MPSMatrix` wrapping `tmp_a` and `tmp_b` with the correct row/column descriptors. The MPS GEMM should only read the declared rows and columns.
   - Step 3: `encode_float32_to_half` converts the result back.

   **However**: The `rb_a` (row bytes) value is computed as `std::max(lda * sizeof(float), mps_rb_a)`. When MPS alignment forces `rb_a > lda * sizeof(float)`, the conversion kernel writes with stride `rb_a / sizeof(float)` but the stale padding bytes between rows are not cleared. If MPS reads beyond the declared matrix dimensions (a known MPS driver behavior for alignment), it encounters stale float32 values that corrupt the accumulation.

4. **Why consistent dimensions work**: When every call uses 3000 frames, the temp buffers are always the same size, and the data is always self-consistent — stale rows from the previous call have the same structure and the MPS reads the same extent.

5. **Why `synchronize_stream` after beam search doesn't help**: The issue is not about pending GPU work. The GPU work from the first call completes fine. The problem is that the **content** of the cached temp buffers retains stale values that are visible to the next call's GPU kernels because the temp buffers are Shared-mode (CPU+GPU coherent).

### Secondary contributing factor: MPS alignment padding reads

`MPSMatrixMultiplication` is known to read up to `rowBytes` per row, even if only `columns * sizeof(T)` bytes are meaningful. When `mps_rb_a > cols_a * sizeof(float)`, the padding zone contains stale data. For the f16 promotion path, the padding zone is filled by `encode_half_to_float32` only for the actual rows — but within each row, the kernel writes `cols_a` elements with stride `rb_a / sizeof(float)`, leaving `(rb_a - cols_a * sizeof(float))` bytes of padding **uninitialized in the temp buffer**. MPS reads these bytes and they contribute to the result.

For the first call with large dimensions, these padding bytes happen to be zero (fresh allocation). For the second call reusing the buffer, they contain float32 residue from the first call.

### Additional suspect: Conv1D batched GEMM with padded path

The encoder Conv1D calls `gemm_batch_strided` with `stride_a=0` (shared weight matrix). When the input time changes, the im2col buffer has different dimensions. The `dispatch_mps_gemm_batched_padded` path for the conv1d GEMM also uses `alloc_temp_buffer` (not the `F16TempCache`), but these are fresh allocations that are released after encoding — so they are not the primary suspect. However, the power-of-2 allocator bucket reuse means a freed temp buffer is recycled into the pool and may be returned with stale content for a subsequent allocation of the same bucket size.

## Recommended Fix

**Option A (minimal, targeted):** Zero the temp buffers in `F16TempCache::get()` and `SdpaF16TempCache::get()` before returning a reused buffer:

```cpp
id<MTLBuffer> get(int idx, NSUInteger bytes) {
    if (bytes <= cap[idx]) {
        // Clear the portion that will be used to prevent stale data leakage
        memset([buf[idx] contents], 0, bytes);
        return buf[idx];
    }
    // ... existing allocation path
}
```

**Option B (more robust):** Pass the exact buffer size (not capacity) to MPS by creating descriptors that match the actual data extent, and ensure all temp buffers are zeroed on allocation. This would also fix the padding-zone issue.

**Option C (diagnostic first):** Add a debug mode that allocates fresh temp buffers for every GEMM call (bypassing the cache). If this fixes the corruption, it confirms the cache is the root cause. Then apply Option A.

## Confidence Level

**Medium-high.** The `F16TempCache` buffer reuse with stale content is the most plausible root cause given:
- The bug manifests only when dimensions change between calls
- The cache returns oversized buffers without clearing
- MPS is known to read beyond declared matrix dimensions for alignment
- Consistent dimensions work because stale data has compatible structure

The exact MPS driver behavior with padding bytes is not publicly documented, so the alignment-read hypothesis cannot be fully confirmed without Apple driver source. A diagnostic build (Option C) would definitively confirm or eliminate this hypothesis.

## Files Examined

| File | Relevant Lines | Role |
|------|---------------|------|
| `src/metal/primitives_gemm.mm` | 980-993, 1006-1076 | F16TempCache + promoted GEMM pipeline |
| `src/metal/ops_sdpa.mm` | 196-214, 216-314 | SdpaF16TempCache + SDPA GEMM |
| `src/metal/primitives_gemm.mm` | 560-649 | MPS GEMM cache (ruled out) |
| `src/metal/allocator.mm` | 56-63, 159-187 | Bucket allocator (ruled out) |
| `src/metal/utils.mm` | 69-161 | Command buffer infrastructure |
| `src/models/whisper.cc` | 84-125, 238-350 | generate() + encode() flow |
| `src/layers/whisper.cc` | 28-64, 67-131 | Encoder + decoder forward_prompt |
| `src/layers/transformer.cc` | 531-557, 699-817 | Decoder state + memory handling |
| `include/ctranslate2/replica_pool.h` | 349-353 | idle() sync callback |
| `src/thread_pool.cc` | 109-124 | Worker run loop |
