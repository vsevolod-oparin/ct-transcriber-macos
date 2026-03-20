# Research: MCP Visual Media for Podcast Companion Experience

**Date:** 2026-03-20
**Scope:** MCP servers for maps, images, knowledge lookup, and image generation — feasibility for enriching podcast listening with visual context

---

## Executive Summary

All four visual content use cases (maps, historical figures, object images, generated illustrations) can be served by existing MCP servers. The key architectural decision: MCP's image support is base64-only with ~1MB limit, which is bandwidth-heavy for media-rich experiences. The recommended approach is hybrid — MCP tools return metadata/URLs, CT Transcriber renders natively using MapKit, AsyncImage, and custom card views. This gives the best performance and richest UX.

---

## Use Case Analysis

### 1. Maps — "Show me this country on a map"

| Server | Provider | Returns | Status |
|--------|----------|---------|--------|
| Google Maps Grounding Lite | Google (official) | Place search, coordinates, weather, routing as JSON | Active, public preview Dec 2025 |
| Mapbox MCP | Mapbox (official) | Geocoding, POI search, routing, isochrones as JSON | Active, released Jun 2025 |
| cablate/mcp-google-map | Community | Geocoding, places, directions, Street View URLs | Community-maintained |

**Key insight:** Map servers return **coordinates and place data (JSON)**, not rendered map images. CT Transcriber needs to render maps itself.

**Rendering approach:** Use macOS-native **MapKit** (MKMapView via NSViewRepresentable). When the LLM calls a maps tool and gets coordinates back, CT Transcriber creates an inline MapKit widget with pins. This is:
- Zero-dependency (MapKit is built into macOS)
- Interactive (user can zoom, pan, satellite view)
- Offline-capable for cached tiles
- Consistent with macOS look and feel

### 2. Historical Figures — "Who was Emperor Minh Mang?"

| Server | Returns | Images? |
|--------|---------|---------|
| Wikipedia MCP (multiple) | Article text, summaries, section extraction | Text only — no image URLs extracted |
| Wikidata MCP (zzaebok) | Structured entity data: labels, descriptions, properties, SPARQL | No images, but has image filename property (P18) |
| Wikipedia + Fetch MCP combo | Article text + fetch image URL from article | Can chain: get article → extract image URL → fetch |

**Key insight:** No Wikipedia MCP server directly returns portrait images. But Wikidata has property P18 (image) which contains the Wikimedia Commons filename. CT Transcriber can:
1. Call Wikidata MCP → get entity with P18 property → construct Wikimedia URL
2. Fetch and display the image natively via AsyncImage

**Bio card rendering:**
```
┌─────────────────────────────┐
│ 🖼️ [Portrait]               │
│ Emperor Minh Mạng           │
│ 1791 — 1841                 │
│ Emperor of Vietnam (Nguyễn) │
│ Second emperor of the       │
│ Nguyễn dynasty...           │
└─────────────────────────────┘
```

Built as a SwiftUI card view with AsyncImage for the portrait.

### 3. Object/Place Images — "Show me Vietnamese beaches"

| Server | Returns | Quality |
|--------|---------|---------|
| Unsplash MCP (multiple) | Image URLs + metadata (author, dimensions) | High (curated photos) |
| Google Image Search MCP | Image URLs or base64 via SerpAPI | Variable |
| Brave Image Search | Image URLs via Brave Search API | Variable |

**Unsplash is best** for high-quality, properly licensed photos. Returns URLs — CT Transcriber renders them natively in a grid layout.

**Image grid rendering:**
```
┌──────┬──────┬──────┐
│ 📷   │ 📷   │ 📷   │
│ Da   │ Nha  │ Phu  │
│ Nang │ Trang│ Quoc │
└──────┴──────┴──────┘
```

### 4. Generated Illustrations — "Draw a thumbnail for this podcast"

| Server | Engine | Returns | Cost |
|--------|--------|---------|------|
| Image Gen MCP (merlinrabens) | DALL-E 3, Gemini, Stability AI | Base64 or saved file | Per-image API cost |
| DALL-E MCP (sammyl720) | OpenAI DALL-E 3 | Saved to disk | ~$0.04/image |
| Replicate Flux MCP (mikeyny) | Flux-Schnell on Replicate | Image URL | ~$0.003/image |
| EverArt MCP | EverArt API | Generated images with style control | Per-image |

**Replicate Flux is cheapest** ($0.003/image vs $0.04 for DALL-E). Returns URLs. DALL-E has best quality for complex prompts.

**This is the one case where MCP `ImageContent` (base64) makes sense** — the generated image doesn't exist anywhere as a URL until the server creates it.

---

## MCP Image Protocol Details

### Content Types (MCP Spec 2025-11-25)

```json
TextContent:  { "type": "text", "text": "..." }
ImageContent: { "type": "image", "data": "<base64>", "mimeType": "image/png" }
AudioContent: { "type": "audio", "data": "<base64>", "mimeType": "audio/wav" }
```

- Images are **base64-only** — no URL field in the spec
- Size limit: **~1MB per content block** in Claude Desktop
- Multiple content blocks can be mixed in one tool result
- Supported formats: JPG, PNG, GIF, BMP, WebP, SVG
- [Open issue #793](https://github.com/modelcontextprotocol/modelcontextprotocol/issues/793) requesting URL support — not yet added

### MCP Apps Extension (January 2026)

- [Announcement](http://blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/)
- Allows tools to return **interactive HTML/JS UIs** in sandboxed iframes
- Supported by Claude, ChatGPT, Goose, VS Code
- Use cases: interactive maps, dashboards, knowledge panels
- Uses `ui://` URI scheme
- Could render Mapbox GL JS maps, image galleries, interactive timelines

---

## Recommended Architecture

### Hybrid Rendering (recommended)

```
MCP Tool Result (JSON metadata)
        │
        ▼
CT Transcriber Native Rendering
        │
        ├── MapKit widget (from coordinates)
        ├── AsyncImage (from URLs)
        ├── Bio card (from Wikidata properties)
        ├── Image grid (from Unsplash URLs)
        └── Inline image (from base64 ImageContent)
```

**Why hybrid:**
- MCP servers return **lightweight data** (coordinates, URLs, entity properties) — fast, no 1MB limit
- CT Transcriber renders **rich native UI** — MapKit, AsyncImage, custom SwiftUI views
- Only generated images use base64 `ImageContent` (they don't have a pre-existing URL)
- Better UX than base64-only: interactive maps, zoomable images, proper loading states

### Tool-Result Card Types

| Card Type | Data Source | Rendering |
|-----------|------------|-----------|
| **Map card** | `{ lat, lng, name, description }` | MKMapView with annotation pin |
| **Bio card** | `{ name, birth, death, description, imageURL }` | VStack with AsyncImage + text |
| **Image card** | `{ url, title, author }` | AsyncImage with caption |
| **Image grid** | `[{ url, title }]` | LazyVGrid of AsyncImage |
| **Generated image** | `{ base64, mimeType }` | Decoded NSImage displayed inline |

### Data Flow for Podcast Companion

```
Transcript: "...город Дананг, на берегу моря..."
        │
User asks: "Show me Danang"
        │
        ▼
LLM decides to call tools:
  1. Mapbox geocode("Danang, Vietnam") → { lat: 16.047, lng: 108.206, name: "Da Nang" }
  2. Wikipedia summary("Da Nang") → { text: "Da Nang is a city..." }
  3. Unsplash search("Da Nang Vietnam beach") → [{ url: "...", author: "..." }, ...]
        │
        ▼
LLM composes response with tool results
CT Transcriber renders:
  ┌─────────────────────────────────────┐
  │ 🗺️ Da Nang, Vietnam                │
  │ [Interactive MapKit with pin]       │
  │                                     │
  │ Da Nang is a coastal city in        │
  │ central Vietnam known for its       │
  │ sandy beaches and history...        │
  │                                     │
  │ 📷 📷 📷                            │
  │ [Beach photos from Unsplash]        │
  └─────────────────────────────────────┘
```

---

## Implementation Requirements

### New UI Components (M12e-specific)

1. **MapCardView** — NSViewRepresentable wrapping MKMapView. Accepts coordinates, annotations, zoom level. Renders inline in tool-call result card.

2. **BioCardView** — SwiftUI view with AsyncImage for portrait, name, dates, short description. Used for historical figures, notable people.

3. **ImageGridView** — LazyVGrid of AsyncImage items. For search results (Unsplash, Google Images). Supports tap-to-expand.

4. **GeneratedImageView** — Decodes base64 MCP ImageContent, displays as NSImage. For DALL-E/Flux output.

5. **Tool-result renderer** — Detects structured content type from tool result JSON and selects the appropriate card view. Fallback: plain text display.

### MCP Servers to Configure

| Server | Purpose | API Key Required | Transport |
|--------|---------|-----------------|-----------|
| Mapbox MCP | Geocoding, places | Yes (free tier available) | Stdio |
| Wikipedia MCP | Article summaries | No | Stdio |
| Wikidata MCP | Entity properties | No | Stdio |
| Unsplash MCP | Photo search | Yes (free tier: 50 req/hr) | Stdio |
| Image Gen MCP | Thumbnail generation | Yes (DALL-E or Replicate) | Stdio |

### Dependencies on M12a

M12e requires M12a (MCP Infrastructure) to be complete:
- MCPClientManager for server lifecycle
- Tool-call UI framework for rendering cards
- Settings UI for API key configuration

Can be built in parallel with M12b-d since it uses different servers.

---

## Cost Estimates

| Service | Free Tier | Paid |
|---------|-----------|------|
| Mapbox | 100K requests/month | $0.50/1K after |
| Unsplash | 50 requests/hour | Contact for more |
| DALL-E 3 | None | ~$0.04/image |
| Replicate Flux | $5 free credit | ~$0.003/image |
| Wikipedia/Wikidata | Unlimited | Free |

For a typical podcast session (5-10 visual lookups), costs are negligible.

---

## Sources

- [MCP Specification — Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
- [MCP Apps Extension](http://blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/)
- [Google Maps Grounding Lite MCP](https://developers.google.com/maps/ai/mcp)
- [Mapbox MCP Server](https://github.com/mapbox/mcp-server)
- [Wikipedia MCP](https://github.com/Rudra-ravi/wikipedia-mcp)
- [Wikidata MCP](https://github.com/zzaebok/mcp-wikidata)
- [Unsplash MCP](https://github.com/hellokaton/unsplash-mcp-server)
- [Image Gen MCP](https://github.com/merlinrabens/image-gen-mcp-server)
- [MCP ImageContent Issue #793](https://github.com/modelcontextprotocol/modelcontextprotocol/issues/793)
- [Image Viewer MCP](https://mcpmarket.com/server/image-viewer)
