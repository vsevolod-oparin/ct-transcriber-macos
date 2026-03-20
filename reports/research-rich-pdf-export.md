# Research: Rich PDF Export with Illustrations

**Date:** 2026-03-20
**Scope:** Professional-quality PDF generation from podcast transcripts + research, with embedded images, maps, and formatting

---

## Executive Summary

The recommended approach is **HTML/CSS → WKWebView.createPDF()** — zero external dependencies, full CSS layout power, image embedding, and professional typography. The existing markdown parser can be reused to generate HTML. For the MCP workflow, the LLM can generate the document structure (sections, image placement, captions) as part of the conversation, then CT Transcriber renders it to PDF via WebKit.

---

## Approach: HTML/CSS + WebKit

### Why This Wins

| Criterion | HTML/CSS + WebKit | Typst | LaTeX | TPPDF |
|-----------|------------------|-------|-------|-------|
| Dependencies | None (macOS built-in) | ~20MB binary | 80MB–4.5GB | SPM package |
| Image support | Base64 data URIs, file:// URLs | PNG, JPG, SVG | Yes (complex setup) | Yes |
| Typography quality | Good (web fonts, CSS) | Excellent (near-LaTeX) | Best | Basic |
| CSS/layout control | Full (flexbox, grid, @page) | Custom markup | LaTeX markup | Imperative API |
| Learning curve | HTML/CSS (widely known) | Typst markup (new) | LaTeX (steep) | Swift API |
| Iteration speed | Fast (change CSS, reload) | Fast (change markup) | Slow (recompile) | Slow (recompile) |
| TOC generation | JavaScript or manual | Built-in | Built-in | Manual |
| Running headers/footers | Limited (@page CSS) | Built-in | Built-in | Built-in |
| Hyphenation | CSS hyphens: auto | Built-in | Built-in | No |
| macOS API | `WKWebView.createPDF()` (macOS 12+) | Process subprocess | Process subprocess | Direct Swift |

### API

```swift
let webView = WKWebView(frame: .zero)
webView.loadHTMLString(html, baseURL: nil)
// Wait for load...
let pdfConfig = WKPDFConfiguration()
pdfConfig.rect = CGRect(x: 0, y: 0, width: 595, height: 842) // A4
let data = try await webView.pdf(configuration: pdfConfig)
```

Or use [swift-html-to-pdf](https://github.com/coenttb/swift-html-to-pdf) for async/await with actor-based pooling.

### What CSS Gives You

```css
@page {
  size: A4;
  margin: 2.5cm;
}

body {
  font-family: 'Georgia', serif;
  font-size: 11pt;
  line-height: 1.6;
  color: #333;
  hyphens: auto;
}

h1 { font-size: 24pt; margin-top: 2em; }
h2 { font-size: 18pt; border-bottom: 1px solid #ccc; }

img.illustration {
  width: 100%;
  border-radius: 8px;
  margin: 1em 0;
}

img.portrait {
  float: right;
  width: 150px;
  margin: 0 0 1em 1em;
  border-radius: 50%;
}

.map-container {
  width: 100%;
  height: 300px;
  background: url('map-image.png') center/cover;
  border-radius: 8px;
}

pre code {
  background: #f5f5f5;
  padding: 1em;
  border-radius: 4px;
  font-family: 'SF Mono', monospace;
  font-size: 9pt;
}

table {
  width: 100%;
  border-collapse: collapse;
}
th, td {
  border: 1px solid #ddd;
  padding: 8px;
  text-align: left;
}
```

---

## Content Pipeline

### Current (plain export)

```
Conversation messages → NSAttributedString → NSTextView.dataWithPDF
```

Result: plain text with basic formatting, no images, no layout.

### Proposed (rich export)

```
Conversation messages + tool results (images, maps, entities)
        │
        ▼
LLM structures the document (sections, image placement, captions)
        │
        ▼
CT Transcriber generates HTML from structured content
        │
        ▼
CSS stylesheet applies professional formatting
        │
        ▼
WKWebView.createPDF() → polished PDF
```

### HTML Generation from Existing Parser

The `parseMarkdown()` function already splits content into segments. Converting to HTML is a direct mapping:

| Segment | SwiftUI (current) | HTML (proposed) |
|---------|-------------------|-----------------|
| `.text(String)` | `Text(AttributedString(markdown:))` | `<p>markdown-to-html</p>` |
| `.codeBlock(code, lang)` | `CodeBlockView` | `<pre><code class="lang">...</code></pre>` |
| `.header(text, level)` | `Text` with scaled font | `<h1>` through `<h6>` |
| `.table(rows)` | `TableView` | `<table><tr><td>...</td></tr></table>` |

New content types for rich PDF:

| Content | HTML |
|---------|------|
| Image (URL) | `<img src="url" class="illustration">` |
| Image (base64) | `<img src="data:image/png;base64,...">` |
| Portrait + bio | `<div class="bio-card"><img class="portrait" src="..."><h3>Name</h3><p>...</p></div>` |
| Map (static image) | `<img src="static-map-url" class="map">` |
| Map (screenshot) | `<img src="data:image/png;base64,..." class="map">` |

### Map Rendering for PDF

Interactive MapKit can't be directly embedded in HTML. Options:
1. **Static Maps API** — Google/Mapbox static map image URL with pins (simplest)
2. **MapKit snapshot** — `MKMapSnapshotter` renders a map image programmatically, embed as base64
3. **Mapbox GL JS in WebView** — render interactive map in the same WebView, print captures it (complex)

`MKMapSnapshotter` is the best fit — native macOS API, no external dependencies:
```swift
let options = MKMapSnapshotter.Options()
options.region = MKCoordinateRegion(center: coordinate, span: span)
options.size = CGSize(width: 600, height: 300)
let snapshotter = MKMapSnapshotter(options: options)
let snapshot = try await snapshotter.start()
let image = snapshot.image // NSImage → base64 → <img> in HTML
```

---

## MCP Workflow Integration

### The Key Insight

The LLM doesn't just collect information — it **designs the document**. The MCP workflow becomes:

```
1. User transcribes podcast
2. User chats, asks questions, LLM calls MCP tools:
   - Wikipedia → article summaries, entity data
   - Unsplash → relevant photos
   - Maps → location coordinates
   - Image Gen → podcast thumbnail
3. User says: "Create a nice PDF report about this podcast"
4. LLM structures the document:
   - Title, subtitle, author
   - Introduction (summarized from transcript)
   - Sections organized by topic (extracted from transcript)
   - Each section has: text, relevant images, maps, bio cards
   - Conclusion, key takeaways
5. CT Transcriber renders HTML → PDF
```

### Step 4 in Detail: LLM as Document Designer

The LLM outputs a **structured document plan** as JSON:

```json
{
  "title": "Vietnam Travel Guide — From the Podcast",
  "subtitle": "Key destinations and tips from Episode 12",
  "sections": [
    {
      "heading": "Da Nang — Beach City",
      "text": "Da Nang is a coastal city in central Vietnam...",
      "media": [
        { "type": "map", "lat": 16.047, "lng": 108.206, "zoom": 12 },
        { "type": "image", "url": "https://unsplash.com/...", "caption": "My Khe Beach" }
      ]
    },
    {
      "heading": "Hue — Imperial History",
      "text": "The ancient capital of Vietnam...",
      "media": [
        { "type": "bio", "name": "Emperor Minh Mạng", "years": "1791–1841",
         "imageURL": "https://...", "description": "Second emperor of Nguyễn dynasty" },
        { "type": "image", "url": "https://unsplash.com/...", "caption": "Imperial Citadel" }
      ]
    }
  ],
  "conclusion": "Key takeaways from the podcast..."
}
```

CT Transcriber takes this JSON → generates HTML with CSS → WebKit renders to PDF.

### MCP Tool for PDF Generation

This could itself be an MCP tool! The LLM calls:

```
Tool: generate_pdf
Input: { document_plan: {...}, style: "magazine" }
Output: PDF file saved to user-specified location
```

The tool is implemented natively in CT Transcriber (not as an external MCP server) — it has access to WebKit, MapKit snapshotter, and the local file system.

### Alternative: LLM Generates HTML Directly

Simpler approach — skip the structured JSON, let the LLM output HTML directly:

```
User: "Create a nice PDF report about this podcast"
LLM: Here's the document. [calls generate_pdf tool with HTML content]
```

The LLM is good at generating HTML. CT Transcriber wraps it in a CSS template and renders via WebKit. This is simpler but gives less control to the app over styling consistency.

**Recommended: hybrid** — LLM generates the structured JSON plan, CT Transcriber owns the HTML template and CSS. This separates content from presentation.

---

## Implementation Plan

### Phase 1: HTML Template Engine

- Create `RichPDFExporter` service
- HTML template with CSS for professional formatting (fonts, spacing, colors)
- Convert markdown segments to HTML
- Embed images as base64 data URIs
- `WKWebView.createPDF()` for rendering
- Replace current `ConversationExporter.exportPDF` or add as "Export as Rich PDF..."

### Phase 2: Image & Map Embedding

- Fetch images from URLs → convert to base64 for HTML embedding
- `MKMapSnapshotter` for map images from coordinates
- Image gallery layout in CSS

### Phase 3: LLM-Designed Documents

- Structured document plan JSON schema
- LLM generates plan from conversation content + tool results
- CT Transcriber renders plan to HTML → PDF
- Multiple CSS themes (magazine, academic, minimal)

### Conversational Document Editing

The document isn't a one-shot export — it's an **iterative, conversational process**:

```
User: "Create a PDF report about this podcast"
LLM: [generates document plan, shows preview]
User: "Move the map to the top of the Danang section"
LLM: [patches section.media order, preview re-renders]
User: "Make the introduction shorter"
LLM: [rewrites section.text for intro, preview updates]
User: "Add a photo of Hue's imperial citadel"
LLM: [calls Unsplash MCP → gets image → adds to section.media, preview updates]
User: "Looks good, export it"
→ PDF saved
```

**Key design decisions:**
- Document plan is **conversation state** — the structured JSON lives in the chat context, the LLM reads and modifies it on each turn
- **Section-level edits** — LLM patches the specific section the user referenced, doesn't regenerate the entire plan (faster, preserves user's prior approvals)
- **Live preview** — `WKWebView` in a sheet re-renders HTML on each edit. User sees changes instantly.
- **Undo support** — each edit creates a snapshot. User can reject and revert.
- **"Export when ready" button** on the preview sheet — user controls when the final PDF is saved

This is essentially **conversational document editing** — the LLM is content creator + layout designer, the user directs via natural language, CT Transcriber is the rendering engine.

### Relationship to M12

- **M12a required**: MCP infrastructure for tool calling
- **M12e (Rich Media) helps**: images, maps, entity data already collected in conversation
- **New tool**: `generate_pdf` — native tool that CT Transcriber handles internally
- The rich PDF export is the **output** of the podcast companion workflow

---

## Fallback: Typst

If WebKit's PDF output isn't polished enough (no running headers/footers, limited page break control), Typst is the upgrade path:

- Single binary ~20MB (can be bundled or downloaded on first use, like Miniconda)
- Near-LaTeX output quality
- Built-in TOC, page numbers, running headers
- Image support (PNG, JPG, SVG)
- Apache 2.0 license
- Integration via `Process` subprocess (same pattern as Python transcription)

The two can coexist: WebKit for quick exports, Typst for "publication-quality" export.

---

## Sources

- [WKWebView.createPDF documentation](https://developer.apple.com/documentation/webkit/wkwebview/3650489-createpdf)
- [swift-html-to-pdf](https://github.com/coenttb/swift-html-to-pdf)
- [MKMapSnapshotter](https://developer.apple.com/documentation/mapkit/mkmapsnapshotter)
- [Typst](https://typst.app/) — modern typesetting
- [CSS Paged Media](https://www.w3.org/TR/css-page-3/) — @page rules for print
- [TPPDF](https://github.com/techprimate/TPPDF) — Swift PDF library
