# Planning: Post v0.4.0 Development Roadmap

**Date:** 2026-03-20
**Current version:** 0.4.0
**Codebase:** 39 Swift files, ~25,000 lines

---

## Completed Milestones

All milestones M0–M11b and M13 are complete. The FSM refactoring, anti-pattern audit, crash fixes, performance optimization, and video sizing fixes were done as unplanned work between M11b and M13.

## Next Milestone

**M12: MCP Support** — the only planned milestone remaining. Extends LLM with Model Context Protocol tool use (image search, maps, code execution, etc.). Requires:
- Research MCP Swift SDK availability
- Design tool-call UI in chat (expandable cards)
- Implement MCP client connecting to local MCP servers
- Allow user to configure MCP server endpoints

## High-Value Improvements — COMPLETED

| Item | Status | Notes |
|------|--------|-------|
| Code syntax highlighting | ✅ Done | Regex-based, zero dependencies. Keywords, types, strings, numbers, comments, decorators. Cached. |
| `@Query` instead of `refreshConversations()` | ✅ Done | Removed ~20 manual refresh calls. SwiftData auto-updates via `@Query`. |
| Drag attachment to Finder | ✅ Done | `.onDrag` with NSItemProvider on AttachmentView. |
| Swift 6 strict concurrency | ✅ Done | `SWIFT_STRICT_CONCURRENCY = complete`. Zero concurrency warnings. |

## Lower-Priority Deferred Items

| Item | Source | Notes |
|------|--------|-------|
| Share extension | M9 | Finder share menu "Open in CT Transcriber" |
| Line-level timestamp click-to-seek | M7b+ | Infrastructure ready via `seekRequest` |
| `NSCache` for video thumbnails | M7b+ | Current in-memory loading sufficient |
| `isDynamicContentLocked` for scroll perf | M8c | Disable layout recalc during rapid scroll |
| 1000+ message stress test | M8c | Not yet tested at scale |
| Subprocess timeout hardening | M11b | Mitigated by `process.terminate()` |
| Timer → `.onReceive(Timer.publish)` | Audit #7 | Functional but not idiomatic SwiftUI |
| Priority queue for transcriptions | TelegramSwift research | User-initiated preempts auto-queued |
| Lite Mode / Low Power | TelegramSwift research | Reduce streaming frequency, smaller models |
| Extract into Swift Packages | TelegramSwift research | When codebase exceeds ~50 files (currently 40) |

**Rejected:** Visibility-based audio playback pause — bad UX for podcasts/long audio. Mini-player handles scroll-out correctly.

## Recommended Priority Order

1. **Line-level timestamp click-to-seek** — small, high UX value for transcription users
2. **M12: MCP** — biggest feature expansion
3. **1000+ message stress test** — validates NSTableView at scale
