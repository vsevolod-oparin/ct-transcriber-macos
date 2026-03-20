# Research: Vision-Language Models (VLMs) for CT Transcriber

**Date:** 2026-03-20
**Scope:** VLM landscape, use cases for audio/video transcription app, technical integration, local vs API trade-offs

---

## Executive Summary

VLMs unlock a category of features no competing transcription app offers: **understanding what is shown in a video, not just what is said**. The highest-value use cases are: (1) lecture video visual extraction — slides, whiteboard, diagrams combined with audio transcript, (2) image-in-chat understanding — users drop images and the LLM analyzes them, (3) PDF quality feedback loop — VLM reviews rendered PDFs for layout issues before export.

The lowest-effort first step is enabling image attachments in LLM requests — CT Transcriber already stores and displays images but never sends them to the LLM. This is ~200 lines of changes across 4-5 files.

CTranslate2 does NOT support VLMs. Local inference should use MLX (via mlx-vlm) or LM Studio. Moondream 3 (2B params, 4-bit) runs at 35+ tok/s on M1 Max with ~4GB memory.

---

## 1. Available VLMs

### API-Based

| Provider | Model | Image Cost | Video Support | Notes |
|----------|-------|-----------|---------------|-------|
| Anthropic | Claude Sonnet/Opus 4.6 | ~$0.005-0.008/image | Frames only | Up to 600 images/req |
| OpenAI | GPT-4o | ~$0.005-0.01/image | Frames only | detail: low/high/auto |
| Google | Gemini 2.5 Flash | ~$0.0008/10 frames | **Native video input** | Cheapest, 1 FPS sampling |
| Google | Gemini 2.5 Pro | ~$0.004/10 frames | **Native video input** | Best video comprehension |

**Key insight:** Gemini accepts raw video files and samples at 1 FPS internally. A 10-minute video costs ~$0.054 with Flash. Claude/GPT-4o require extracting frames as images.

### Local (Apple Silicon)

| Model | Params | Size (4-bit) | Speed (M-series) | Memory | Strength |
|-------|--------|-------------|-------------------|--------|----------|
| Moondream 3 | 2B | ~1.2 GB | 35+ tok/s | ~4 GB | Tiny, fast, good OCR |
| Qwen2.5-VL-7B | 7B | ~4.5 GB | 15-25 tok/s | ~8 GB | Strong multilingual, video |
| GLM-4.5V | 9B | ~5.5 GB | 10-20 tok/s | ~10 GB | Best open-source benchmarks |

**MLX-VLM** is the framework for Apple Silicon. **LM Studio** provides an OpenAI-compatible API endpoint — CT Transcriber's existing `OpenAICompatibleService` works with it immediately.

---

## 2. Prioritized Use Cases

### Priority 1: Image-in-Chat Understanding

**Effort:** Small (~200 lines) | **Impact:** Unlocks all VLM features

CT Transcriber already stores images (`.image` attachment kind) and displays them. But `ChatMessageDTO` is text-only and `buildMessageDTOs()` ignores image attachments. Changes needed:

1. Refactor `ChatMessageDTO` to support content blocks (text + image)
2. Update `AnthropicService` to format multimodal messages (content blocks with `type: "image"`)
3. Update `OpenAICompatibleService` for `image_url` with data URIs
4. Update `buildMessageDTOs()` to include image attachments as base64

**This is the prerequisite for everything else.**

### Priority 2: Lecture Video Visual Extraction

**Effort:** Medium (~500-800 lines) | **Impact:** Unique differentiator

No transcription app combines audio transcription with VLM-powered visual content extraction.

**Pipeline:**
```
Video file
├── Audio → Whisper → Timestamped transcript (existing)
└── Video → Scene change detection → Keyframes → VLM → Slide/whiteboard text
                                                          └── Merge by timestamp
```

**Scene change detection** reduces costs 24x: 60-min lecture with periodic sampling = $5.97 (Claude), with scene detection (~30 unique slides) = $0.25.

**AVFoundation** provides frame extraction (`AVAssetImageGenerator`). Scene changes detected via histogram comparison between consecutive frames.

**Output:** Enhanced transcript with visual context:
```
## Slide 3: Neural Network Architecture [2:15 - 5:30]

[Slide content:]
Title: "CNN Layers"
- Input: 224x224x3
- Conv1: 64 filters, 3x3
[Diagram: conv → pool → conv → pool → FC]

[Audio transcript:]
"So in this slide we can see the architecture..."
```

### Priority 3: PDF Quality Review Loop

**Effort:** Small (~150 lines) | **Impact:** Quality multiplier for M12f

```
LLM designs document → WebKit renders → PDF
                                          ↓
                                   VLM reviews pages
                                          ↓
                                   "Header truncated on page 3,
                                    image overlaps margin on page 5"
                                          ↓
                                   LLM fixes → re-render
```

Convert PDF pages to images via PDFKit, send to VLM with review prompt.

### Priority 4: Local VLM via LM Studio

**Effort:** Near-zero | **Impact:** Privacy-first option

LM Studio speaks OpenAI-compatible API. Users configure it as a provider with `baseURL: "http://localhost:1234"`. CT Transcriber's existing `OpenAICompatibleService` works immediately. Just needs documentation and optionally a preset.

### Priority 5: VLM-as-MCP-Server

**Effort:** Medium | **Impact:** Text-only LLMs can delegate vision tasks

A local VLM exposed as an MCP server with `analyze_image` tool. Claude (text-only tier) calls the tool, local Moondream 3 processes the image, returns description. Vision stays local, orchestration is cloud.

---

## 3. Technical Integration

### API Formats

**Anthropic:**
```json
{ "role": "user", "content": [
    { "type": "image", "source": { "type": "base64", "media_type": "image/jpeg", "data": "..." } },
    { "type": "text", "text": "Describe this image." }
] }
```

**OpenAI:**
```json
{ "role": "user", "content": [
    { "type": "image_url", "image_url": { "url": "data:image/jpeg;base64,..." } },
    { "type": "text", "text": "Describe this image." }
] }
```

### Required Code Changes (Priority 1)

```swift
// New: multimodal content blocks
enum ChatContentBlock {
    case text(String)
    case imageBase64(mediaType: String, data: String)
}

struct ChatMessageDTO {
    let role: String
    let content: [ChatContentBlock]
}
```

Update `buildMessageDTOs()` to include `.image` attachments as base64 content blocks. Update both API services to format multimodal messages.

### Frame Extraction (Priority 2)

```swift
// AVAssetImageGenerator for periodic/keyframe extraction
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
// Extract at scene changes or fixed intervals
```

### CTranslate2 Limitation

CTranslate2 does NOT support VLMs — text-only transformer architectures only. Local VLM inference must use MLX or LM Studio.

---

## 4. Cost Analysis

| Scenario | Claude Sonnet | Gemini Flash | Local (Moondream) |
|----------|--------------|-------------|-------------------|
| 1 screenshot | $0.008 | $0.0005 | $0 |
| 10 lecture slides | $0.083 | $0.005 | $0 |
| 60-min lecture (scene detection, ~30 slides) | $0.25 | $0.015 | $0 |
| 60-min lecture (naive 1/5s sampling) | $5.97 | $0.36 | $0 |
| PDF review (10 pages) | $0.08 | $0.005 | $0 |

---

## 5. Competitive Landscape

No transcription app currently combines audio transcription with VLM visual extraction:
- **Descript** — task-specific CV (speaker centering), no VLM
- **Otter.ai** — no visual analysis
- **ScreenApp** — basic video OCR, not VLM-powered
- **MacWhisper** — audio only, no video analysis

CT Transcriber would be first to offer comprehensive audio+visual understanding.

---

## 6. Implementation Phases

```
Phase 1: Image-in-Chat (prerequisite, ~200 lines)
├── ChatMessageDTO → multimodal content blocks
├── AnthropicService multimodal formatting
├── OpenAICompatibleService multimodal formatting
└── buildMessageDTOs() includes image attachments

Phase 2: Video Visual Extraction (new milestone)
├── VideoFrameExtractor service (AVFoundation)
├── Scene-change detection
├── Frame → VLM analysis pipeline
└── Transcript + visual content merger

Phase 3: PDF Quality Loop (after M12f)
├── PDF page → CGImage converter
├── VLM review prompt templates
└── Document editing feedback integration

Phase 4: Local VLM (parallel, any time)
├── LM Studio integration docs
└── (Future) Custom MLX-VLM MCP server
```

---

## Sources

- [Claude Vision API](https://platform.claude.com/docs/en/build-with-claude/vision)
- [OpenAI Images and Vision](https://developers.openai.com/api/docs/guides/images-vision)
- [Gemini Video Understanding](https://ai.google.dev/gemini-api/docs/video-understanding)
- [MLX-VLM](https://github.com/Blaizzy/mlx-vlm)
- [LM Studio v0.3.4](https://lmstudio.ai/blog/lmstudio-v0.3.4)
- [Moondream 3](https://moondream.ai/blog/moondream-station-m3-preview)
- [Vision Language Models 2025 (HuggingFace)](https://huggingface.co/blog/vlms-2025)
- [Native LLM/MLLM on Apple Silicon (arXiv)](https://arxiv.org/html/2601.19139v2)
- [CTranslate2](https://github.com/OpenNMT/CTranslate2)
