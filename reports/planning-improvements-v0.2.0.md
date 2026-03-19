# Improvement Opportunities — v0.2.0

**Date:** 2026-03-19
**Context:** After comprehensive 6-agent audit and fixes, identified areas for future work.

---

## Quick Wins

| # | Improvement | Effort | Impact |
|---|-------------|--------|--------|
| 1 | **Search conversations** — Cmd+F to filter sidebar by title/content | 1-2 hr | High for users with 50+ conversations |
| 2 | **SRT subtitle export** — right-click transcription → "Export as SRT". Segment data already has timestamps | 1 hr | Medium — useful for video editors |
| 3 | **System prompt per conversation** — text field for custom instructions ("You are a translator") | 1-2 hr | High for power users |

## Distribution

| # | Improvement | Effort | Impact |
|---|-------------|--------|--------|
| 4 | **Code signing + notarization** — $99/yr Apple Developer Program, eliminates Gatekeeper issues | 1 hr + $99 | Critical for non-technical users |
| 5 | **Auto-update via Sparkle** — check for new versions, self-update | 2-3 hr | High — standard for macOS apps |
| 6 | **Homebrew cask** — `brew install --cask ct-transcriber` | 30 min | Medium for tech users |

## Quality & Technical Debt

| # | Improvement | Effort | Impact |
|---|-------------|--------|--------|
| 7 | **Unit tests** — zero tests for ChatViewModel, services, models. Core logic untested | 4-6 hr | High — prevents regressions |
| 8 | **@Query for conversations** — replace manual `refreshConversations()` with reactive SwiftUI @Query | 1-2 hr | Medium — eliminates redundant DB fetches |
| 9 | **Conversation search in SwiftData** — `#Predicate` for filtering by title or message content | 1 hr | Needed for #1 |

## Features (Future Milestones)

| # | Improvement | Effort | Impact |
|---|-------------|--------|--------|
| 10 | **Markdown rendering** — code blocks, bold, headers in assistant messages (ROADMAP M13) | 4-6 hr | High for LLM chat |
| 11 | **Live microphone transcription** — real-time whisper from mic input | 8+ hr | High — new use case |
| 12 | **Speaker diarization** — who said what | 4-6 hr | Medium — multi-speaker conversations |

## Recommended Priority

1. **Quality first:** Unit tests (#7), @Query (#8) — prevents regressions as features are added
2. **Quick wins:** Search (#1), system prompt (#3) — high value, low effort
3. **Distribution:** Code signing (#4) — eliminates #1 user complaint
4. **Features:** Markdown (#10), SRT export (#2)
