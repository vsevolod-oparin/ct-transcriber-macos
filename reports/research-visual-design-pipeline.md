# Research: Automated Visual Design Review Pipeline

**Date:** 2026-05-04
**Scope:** Cloud-available vision-language models, automated screenshot capture, multi-model orchestration, integration with opencode

---

## Executive Summary

The CT Transcriber codebase (~41 Swift files, ~26k lines) benefits from continuous visual review — catching regressions, misalignments, and UX regressions before users do. This report defines a fully automated pipeline that:

1. Launches the app, navigates every view via AppleScript, captures screenshots
2. Feeds screenshots through 4 vision models, each specialized for different analysis types
3. Aggregates findings into a structured report
4. Generates actionable fix tasks for opencode

All models are cloud-API available. No Claude, no OpenAI, no Gemini. Total cost per full review: **under $0.05**.

---

## 1. Model Selection

### 1.1 Models by Role

| Role | Model | Platform | Why This Model | Cost per screenshot |
|------|-------|----------|---------------|---------------------|
| **Element Grounding** | GLM-4.5V | z.ai | GUI-specific training — icon detection, desktop assistance, spatial reasoning. SOTA on 41 multimodal benchmarks. Same API key as DeepSeek V4. | ~$0.001 |
| **Layout & Spacing** | Qwen2.5-VL-32B | SiliconFlow | Visual agent — structured element extraction, understands bounding boxes and spatial relationships. 128K context for multi-screenshot analysis. | ~$0.0005 |
| **Aesthetic & Style** | Qwen3-VL-235B | OpenRouter | Best open-weight VL. Beats Gemini 2.5 Pro on visual perception. 1M context — can analyze all screenshots in one call. | ~$0.003 |
| **Flow & Interaction** | Kimi K2.6 | api.moonshot.ai | Only model with native video input. Reviews screen recordings of the app *in use* — catches dead interactions, awkward transitions, missing animations. | ~$0.005 |
| **Code Fixes** | DeepSeek V4 | z.ai (same as today) | Generates SwiftUI fixes from structured findings. Already integrated into opencode workflow. | N/A (already in use) |

### 1.2 Why Not Other Models

| Model | Reason Excluded |
|-------|----------------|
| Claude Opus 4.7 | Best visual-acuity but $15/M input — 100x more expensive. User preference: avoid Claude. |
| GPT-5.4 | User preference: avoid OpenAI. |
| Gemini 2.5 Flash | User preference: avoid Google. |
| UI-Venus-1.5 | No cloud API yet. Requires self-host GPU. |
| MiMo V2 Omni | Strong but not focused on UI aesthetics. Used only for autonomous interaction testing (future phase). |
| MiniMax M2.7 | Text-first, vision via plugin only. Not natively multimodal. |

### 1.3 Cost Estimate (Full Review, 20 Screenshots)

| Model | Input (image tokens) | Output (text) | Cost |
|-------|---------------------|---------------|------|
| GLM-4.5V × 20 images | ~20K tokens | ~2K tokens | $0.005 |
| Qwen2.5-VL-32B × 20 images | ~20K tokens | ~2K tokens | $0.006 |
| Qwen3-VL-235B (1 batch call) | ~20K tokens | ~3K tokens | $0.029 |
| Kimi K2.6 × 1 screen recording | ~10K tokens | ~1K tokens | $0.009 |
| **Total** | | | **~$0.049** |

Five cents per full review. 100 reviews = $5.

---

## 2. Pipeline Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                      STAGE 1: CAPTURE                            │
│                                                                  │
│  open -a "CT Transcriber" --args --ui-review-mode                │
│                     │                                            │
│         ┌───────────┼───────────┐                                │
│         ▼           ▼           ▼                                │
│   AppleScript   screencapture  screen recording                  │
│   (navigate)    (static PNG)   (QuickTime via CLI)               │
│         │           │           │                                │
│         └───────────┼───────────┘                                │
│                     ▼                                            │
│              /tmp/ui-review/manifest.json                        │
│              { views: ["home","chat","settings",...],            │
│                screenshots: [...] }                               │
└─────────────────────┬────────────────────────────────────────────┘
                      │
┌─────────────────────▼────────────────────────────────────────────┐
│                      STAGE 2: ANALYZE                            │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │ GLM-4.5V     │  │ Qwen2.5-32B  │  │ Qwen3-235B   │           │
│  │ (grounding)  │  │ (layout)     │  │ (aesthetics) │           │
│  │              │  │              │  │              │           │
│  │ "Settings    │  │ "Sidebar     │  │ "Color        │           │
│  │  gear icon   │  │  items have  │  │  contrast     │           │
│  │  is 4px off" │  │  2px gap"    │  │  too low"    │           │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘           │
│         │                 │                 │                    │
│  ┌──────┴─────────────────┴─────────────────┴───────┐           │
│  │              Kimi K2.6 (screen recording)         │           │
│  │  "Tab switch animation stutters, click target     │           │
│  │   on 'Export' is 8px below visible hit area"      │           │
│  └──────────────────────────┬───────────────────────┘           │
└─────────────────────────────┬────────────────────────────────────┘
                      │
┌─────────────────────▼────────────────────────────────────────────┐
│                      STAGE 3: SYNTHESIZE                         │
│                                                                  │
│  ┌──────────────────────────────────────────────────┐           │
│  │  tmp/vlm-review-output.json                      │           │
│  │  {                                               │           │
│  │    "findings": [                                 │           │
│  │      {                                          │           │
│  │        "severity": "HIGH",                       │           │
│  │        "file": "SettingsView.swift:20",          │           │
│  │        "model": "glm-4.5v",                      │           │
│  │        "issue": "Window title bar has 4px gap",   │           │
│  │        "screenshot": "/tmp/ui-review/settings.png"│           │
│  │      },                                         │           │
│  │      ...                                        │           │
│  │    ],                                            │           │
│  │    "deduplicated_count": 17,                     │           │
│  │    "by_severity": {"HIGH": 2, "MED": 7, "LOW": 8}│           │
│  │  }                                               │           │
│  └──────────────────────────────────────────────────┘           │
└─────────────────────┬────────────────────────────────────────────┘
                      │
┌─────────────────────▼────────────────────────────────────────────┐
│                      STAGE 4: FIX                                │
│                                                                  │
│  opencode receives structured findings → generates fixes          │
│  ┌──────────────────────────────────────────────┐               │
│  │  @swift-pro "Fix alignment in SettingsView    │               │
│  │  per finding #4: title bar gap is 4px."      │               │
│  │  WRITABLE FILES: CTTranscriber/Views/         │               │
│  └──────────────────────────────────────────────┘               │
└──────────────────────────────────────────────────────────────────┘
```

---

## 3. Implementation Plan

### 3.1 Stage 1: Capture Script (`scripts/ui-review.sh`)

```
scripts/
├── ui-review.sh              ← Main orchestrator
├── ui-review-capture.sh       ← Screenshot + navigation
├── ui-review-analyze.sh       ← Send to VLMs, collect responses
├── ui-review-synthesize.sh    ← Parse responses → JSON report
├── ui-review-report.sh        ← Display results, dump findings
```

**Navigation coverage** (via AppleScript + keyboard shortcuts):

| # | View | Trigger | What to check |
|---|------|---------|---------------|
| 1 | Empty state | App launch | Welcome screen, layout, no data state |
| 2 | Chat with messages | Load test conversation | Message bubbles, timestamps, media attachments |
| 3 | Sidebar with many items | Scroll, hover, select | Row height, highlight, truncation |
| 4 | Streaming response | Trigger LLM call | Progress indicator, streaming text |
| 5 | Error message | Inject bad API key | Error banner styling, retry button |
| 6 | Settings → General | Cmd+, | Controls, sliders, labels |
| 7 | Settings → LLM | Tab switch | Provider config, key input fields |
| 8 | Settings → Models | Tab switch | Download progress, model list |
| 9 | Settings → Tasks | Tab switch | Task rows, progress bars |
| 10 | About dialog | Menu → About | Version, links, layout |
| 11 | Mini player bar | Play audio, scroll off | Floating bar position, layout |
| 12 | Video attachment | Attach video | Aspect ratio, play button, scrubber |
| 13 | Dark mode | Toggle theme | Color contrast, all views |
| 14 | Font scale max | Cmd+Plus repeatedly | Layout at 2.0x, clipping, overflow |
| 15 | Font scale min | Cmd+Minus repeatedly | Layout at 0.7x, readability |
| 16 | Multi-window | open -n second instance | Settings sync, layout independence |

### 3.2 Stage 2: Analysis Prompts

**GLM-4.5V — Element Grounding**
```
You are a pixel-accurate GUI inspector for a macOS app.
Analyze this screenshot and identify:
1. Any misaligned elements (buttons, icons, text) — give pixel offsets
2. Elements that overlap or clip unexpectedly
3. Icons or text that are truncated
4. Any element whose position differs from macOS HIG conventions
Respond with exact coordinates: "The gear icon at (x=420, y=118) is 4px too low relative to adjacent text"
```

**Qwen2.5-VL-32B — Layout & Spacing**
```
You are a layout and spacing auditor for a SwiftUI macOS app.
Analyze this screenshot and evaluate:
1. Consistent spacing between sections and elements
2. Alignment of related controls (same baseline, same margin)
3. Any wasted whitespace or overly cramped areas
4. Proper SwiftUI padding/inset patterns
5. Visual grouping — do related elements appear grouped?
Rate each category 1-10 and list the 3 worst issues.
```

**Qwen3-VL-235B — Aesthetic & Style**
```
You are a senior macOS UI designer reviewing a SwiftUI app.
Analyze this screenshot against Apple Human Interface Guidelines:
1. Visual hierarchy — what draws attention? Is it correct?
2. Color usage — accent, semantic colors, dark/light mode contrast
3. Typography — font sizes, weights, line heights, consistency
4. Platform authenticity — does it feel macOS-native?
5. Overall visual polish — what would make it look "professional"?
Be specific: "The sidebar uses NSColor.controlBackgroundColor but the chat area uses .windowBackgroundColor — this causes a perceptible seam at the divider."
```

**Kimi K2.6 — Flow & Interaction**
```
Review this screen recording of a macOS app in use.
Evaluate interaction quality:
1. Are click targets large enough and correctly positioned?
2. Are transitions smooth or jarring?
3. Are there any moments where the UI "jumps" or re-layouts unexpectedly?
4. Are loading/empty/error states visually appropriate?
5. Does the tab/keyboard navigation feel natural?
Time-stamp each issue with the frame where it occurs.
```

### 3.3 Stage 3: Synthesis

The synthesis step:
1. Deduplicates findings across models (same issue reported by multiple models = CONFIRMED)
2. Ranks by severity (crash/blocking → misalignment → polish)
3. Maps findings to source files using a manifest of known UI element → file mappings
4. Outputs JSON + human-readable report at `reports/ui-review-$(date +%Y%m%d).md`

### 3.4 Stage 4: opencode Integration

Findings with HIGH severity generate opencode fix commands. The synthesis script outputs:

```bash
opencode "@swift-pro 'Fix alignment in SettingsView: gear icon is 4px low. Writable: CTTranscriber/Views/SettingsView.swift'"
opencode "@swift-pro 'Fix contrast in MessageBubble: user bubble color has 3.2:1 ratio, needs 4.5:1. Writable: CTTranscriber/Views/MessageBubble.swift'"
```

---

## 4. Continuous Integration Hook

The pipeline can run in three modes:

### 4.1 Pre-Release Review
```bash
# Full review of all 16 views, manually triggered
./scripts/ui-review.sh --full --output reports/ui-review-$(date +%Y%m%d).md
```
Runs all 5 models on all 16 views. Takes ~2 minutes. Cost: $0.05.

### 4.2 Per-Commit Diff Review
```bash
# Only review views that changed in the diff
git diff --name-only HEAD~1 | grep 'Views/' | ./scripts/ui-review.sh --changed
```
Only captures and reviews views with code changes. Cost: ~$0.01.

### 4.3 Nightly Regression Scan
```bash
# Scheduled via launchd, compares against baseline
./scripts/ui-review.sh --baseline --regression-check
```
Compares screenshots against last known good state. Alerts on visual regression.

---

## 5. Future: Interactive Testing

Once the passive review pipeline is stable, add active interaction testing using MiMo V2 Omni (available via OpenRouter, $0.30/M input):

```
MiMo V2 Omni autonomously:
1. Launches CT Transcriber
2. Creates a new conversation
3. Attaches a test audio file
4. Starts transcription
5. Opens settings, changes font scale
6. Switches to dark mode
7. Exports a conversation
8. Tests keyboard shortcuts
9. Verifies all operations succeeded
10. Reports: "3/50 steps had unexpected UI behavior"
```

This covers the interaction layer that static screenshots miss — dead buttons, broken event handling, tab order issues.

---

## 6. Dependencies

| Component | Provider | API Key | Cost |
|-----------|----------|---------|------|
| GLM-4.5V | z.ai | Existing `ZAI_API_KEY` | $0.005/review |
| Qwen2.5-VL-32B | SiliconFlow | `SILICONFLOW_API_KEY` (free tier available) | $0.006/review |
| Qwen3-VL-235B | OpenRouter | `OPENROUTER_API_KEY` | $0.029/review |
| Kimi K2.6 | api.moonshot.ai | `MOONSHOT_API_KEY` | $0.009/review |
| DeepSeek V4 | z.ai | Existing `ZAI_API_KEY` | N/A (in use) |

Three new API keys. Two existing. All cloud. Zero GPU rental.

---

## 7. Files to Create

| File | Purpose |
|------|---------|
| `scripts/ui-review.sh` | Main orchestrator — calls capture, analyze, synthesize |
| `scripts/ui-review-capture.sh` | AppleScript + screencapture for all views |
| `scripts/ui-review-analyze.sh` | Parallel VLM API calls, response collection |
| `scripts/ui-review-synthesize.sh` | Deduplicate, rank, map to source files |
| `scripts/ui-review-prompts/` | Prompt templates per model per analysis type |
| `CTTranscriber/App/UIReviewMode.swift` | Launch argument `--ui-review-mode` — opens app with test data, shuts down cleanly after capture |
| `tmp/ui-review-cache/` | Screenshot cache for diff-based reviews |
