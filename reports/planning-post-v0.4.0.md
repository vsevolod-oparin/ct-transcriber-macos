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

## High-Value Improvements (no milestone needed)

| Item | Effort | Impact | Notes |
|------|--------|--------|-------|
| Code syntax highlighting | Small | High | HighlightSwift SPM dependency. 50+ languages, auto-detection, dark mode. |
| `@Query` instead of `refreshConversations()` | Medium | Medium | Current approach re-fetches ALL conversations on every state change. `@Query` gives incremental updates. |
| Drag attachment to Finder | Small | Low | NSItemProvider integration. Right-click "Save As" exists. |
| Swift 6 strict concurrency | Medium | Medium | `@MainActor` and `Task.detached` fixes prepare for it. Strict checking catches remaining edge cases. |

## Lower-Priority Deferred Items

| Item | Source | Notes |
|------|--------|-------|
| Share extension | M9 | Finder share menu "Open in CT Transcriber" |
| Line-level timestamp click-to-seek | M7b+ | Infrastructure ready via `seekRequest` |
| Visibility-based audio playback pause | M7b+ | Pause when cell scrolls off screen |
| `NSCache` for video thumbnails | M7b+ | Current in-memory loading sufficient |
| `isDynamicContentLocked` for scroll perf | M8c | Disable layout recalc during rapid scroll |
| 1000+ message stress test | M8c | Not yet tested at scale |
| Subprocess timeout hardening | M11b | Mitigated by `process.terminate()` |
| Timer → `.onReceive(Timer.publish)` | Audit #7 | Functional but not idiomatic SwiftUI |
| Priority queue for transcriptions | TelegramSwift research | User-initiated preempts auto-queued |
| Lite Mode / Low Power | TelegramSwift research | Reduce streaming frequency, smaller models |
| Extract into Swift Package | TelegramSwift research | When codebase exceeds ~50 files (currently 39) |

## Recommended Priority Order

1. **Code syntax highlighting** — highest UX return for lowest effort
2. **M12: MCP** — biggest feature expansion
3. **`@Query` migration** — architectural improvement for scale
4. **Swift 6 readiness** — future-proofing
