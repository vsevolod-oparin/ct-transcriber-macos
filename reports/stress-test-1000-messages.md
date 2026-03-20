# Stress Test: 1000+ Messages

**Date:** 2026-03-20
**Platform:** Apple Silicon (M4), macOS 14+, SwiftData in-memory store

---

## Summary

NSTableView architecture holds at 1000+ messages with no performance issues. All operations are sub-millisecond per message in the hot paths (hash, sort, scroll). The only concern at extreme scale (10,000+ messages across many conversations) is the full-text search in `filteredConversations`.

---

## 5000-Message Benchmark

| Operation | Total | Per-Message | Notes |
|-----------|-------|-------------|-------|
| Create + SwiftData save | 16,036ms | 3.2ms | One-time bulk insert |
| Sort (timestamp) | 400ms | 0.080ms | `Array.sorted` on 5000 elements |
| Hash (all messages) | 21ms | **0.004ms** | `messageHash` — content length only |
| Markdown parse (2500 msgs) | 70ms | **0.028ms** | `parseMarkdown()` on assistant messages |

## 1000-Message Benchmarks (10-iteration average, XCTest `measure`)

| Test | Average | Steady-State | Notes |
|------|---------|-------------|-------|
| Create + save | 1,305ms | — | One-time cost per conversation |
| Sort + isDeleted filter | 28ms | 16ms | First call 140ms (SwiftData faulting), then 16ms |
| messageHash (all) | 9ms | 6ms | First call 18ms (faulting), then 6ms |
| MessageAnalysis (all) | ~1,241ms total | — | ~1.2ms/msg including line counting |
| Query 10 convos × 100 msgs | 535ms | — | FetchDescriptor + relationship faulting |
| Filtered search 50×50 msgs | 608ms | — | `lowercased().contains()` full scan |

## Analysis by Operation

### Hot Paths (called every render cycle)

| Operation | 100 msgs | 1000 msgs | 5000 msgs | Verdict |
|-----------|----------|-----------|-----------|---------|
| `messageHash` | <1ms | 6ms | 21ms | No concern |
| `sortedMessages` | <1ms | 16ms | 400ms | OK at 1000, watch at 5000 |
| `updateNSView` diff | <1ms | ~5ms | ~25ms | No concern (hash comparison) |

### Cold Paths (called once or on cache miss)

| Operation | 1000 msgs | Verdict |
|-----------|-----------|---------|
| SwiftData create + save | 1.3s | Acceptable (one-time) |
| MessageAnalysis | 1.2ms/msg | Cached per message, not a hot path |
| Markdown parse | 0.028ms/msg | Cached via `@State` |
| Height measurement | 3-25ms/msg | Cached in `heightCache`, only on miss |

### Potential Bottleneck: Conversation Search

`filteredConversations` does `lowercased().contains()` on every message in every conversation:

| Scale | Time | UX Impact |
|-------|------|-----------|
| 10 convos × 50 msgs | ~120ms | Imperceptible |
| 50 convos × 50 msgs | ~608ms | Slight lag during typing |
| 50 convos × 200 msgs | ~2.4s (estimated) | Noticeable lag |
| 100 convos × 200 msgs | ~4.8s (estimated) | Unacceptable |

**Mitigation (already in place):** Search is debounced by SwiftUI's `.searchable` modifier.
**Future fix if needed:** Build a search index, or limit search to conversation titles + most recent N messages.

## What Was Tested

9 test cases covering:
- `testCreate1000Messages` — bulk creation + SwiftData save (measured)
- `testFetch1000Messages` — sort 1000 messages by timestamp (measured)
- `testSortedMessagesWithFilter1000` — sort + isDeleted/modelContext filter (measured)
- `testMessageHash1000` — content hash for all messages (measured)
- `testMarkdownParsing1000` — parseMarkdown on all assistant messages (measured)
- `testMessageAnalysis1000` — MessageAnalysis init for all messages (measured)
- `testCreate5000Messages` — 5000-message end-to-end with detailed timing
- `testQueryPerformance1000` — FetchDescriptor query across 10 conversations
- `testFilteredConversationsSearch` — full-text search across 50 conversations

All tests passed.

## Conclusion

The NSTableView + `heightCache` + `contentLengthSnapshot` architecture scales well to 1000+ messages. Key design decisions that enable this:

1. **Height caching** — `measureRowHeight` (3-25ms) only runs on cache miss. Cached by message ID.
2. **Content hash** — `messageHash` at 0.004ms/msg enables O(n) diff detection in `updateNSView`.
3. **Targeted row updates** — `reloadData(forRowIndexes:)` instead of full `reloadData()` during streaming.
4. **Markdown caching** — `@State cachedSegments` in `MarkdownContentView` prevents re-parsing on every render.
5. **Observation throttling** — 300ms interval for transcription UI updates, 50-char threshold for LLM streaming.

No architectural changes needed for the current usage patterns. Search optimization would be the first thing to address if users reach 100+ conversations with long histories.
