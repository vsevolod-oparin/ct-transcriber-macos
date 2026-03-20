# MCP Integration Research Report for CT Transcriber

**Date:** 2026-03-20
**Scope:** Market research, technical feasibility, use case prioritization for M12: MCP Support

---

## Executive Summary

Model Context Protocol (MCP) is an open standard — originally created by Anthropic, now governed by the Linux Foundation — that provides a universal way for AI applications to connect with external tools and data sources. For CT Transcriber, MCP integration represents the highest-value feature expansion remaining on the roadmap. An official Swift SDK exists (macOS 13.0+, fully compatible with CT Transcriber's macOS 14.0+ target) supporting both stdio and HTTP transports. The ecosystem contains 10,000+ MCP servers covering file systems, calendars, note-taking, web search, CRM, and content creation — many directly relevant to transcription workflows. Market research shows that transcription users consistently demand: (1) action item extraction with task manager integration, (2) meeting summaries pushed to note-taking apps, (3) calendar follow-up creation, (4) content repurposing for social media and blogs, and (5) multi-language translation. MCP provides the standard protocol to deliver all of these without building custom integrations for each service. CT Transcriber is uniquely positioned: no competing macOS-native transcription app currently offers MCP support, making this a strong differentiator.

---

## 1. What is MCP and How It Works

### Architecture

MCP uses a client-server architecture with three roles:
- **MCP Host**: The AI application (CT Transcriber) that coordinates MCP clients
- **MCP Client**: A component within the host that maintains a 1:1 connection with an MCP server
- **MCP Server**: A program that exposes tools, resources, and prompts to clients

### Core Primitives

1. **Tools**: Functions the LLM can call (e.g., "create_calendar_event", "search_web")
2. **Resources**: Data the LLM can read (e.g., file contents, database records)
3. **Prompts**: Templated conversation starters (e.g., "summarize this meeting transcript")

### Transport Mechanisms

- **Stdio**: Server runs as a local subprocess; communication via stdin/stdout. Most secure, recommended for desktop apps.
- **HTTP + SSE**: Server runs remotely as an HTTP service. Better for hosted/shared servers.

### Swift SDK

The official Swift SDK (`modelcontextprotocol/swift-sdk`):
- Swift 6.1+ (Xcode 16+), macOS 13.0+
- Supports both Stdio and HTTP transports
- Full client and server implementation per 2025-11-25 spec
- Fully compatible with CT Transcriber (macOS 14.0+, Swift 6, no sandbox)

### Industry Adoption

MCP adopted by OpenAI (March 2025), Google DeepMind, Microsoft, AWS, Cloudflare, Bloomberg. 10,000+ active servers. Now the industry standard — ChatGPT plugins are being superseded by MCP.

---

## 2. Existing MCP Servers Relevant to Transcription + Chat

### Productivity & Notes
| Server | What It Does |
|--------|-------------|
| Notion MCP (official) | Create pages, search databases, update blocks |
| Obsidian MCP | Read/write/search notes, auto-link concepts |
| Apple Notes MCP | CRUD operations on Apple Notes |
| Todoist MCP (official) | Create tasks, set due dates, manage projects |

### Calendar & Reminders
| Server | What It Does |
|--------|-------------|
| Apple Events MCP | Native macOS Calendar + Reminders via EventKit |
| Apple Calendars MCP | Bridge to macOS Calendar (iCloud, Google, Exchange) |

### Communication
| Server | What It Does |
|--------|-------------|
| Slack MCP (official) | Search channels, send messages |
| Email MCP | Send/receive via IMAP/SMTP |

### Web Search & Research
| Server | What It Does |
|--------|-------------|
| Brave Search MCP | Web search via Brave API |
| Exa MCP | Semantic web search |

### Content Creation
| Server | What It Does |
|--------|-------------|
| Subtitle MCP | Transcription to .srt format |
| Social Media Sync MCP | Cross-platform posting |
| ElevenLabs MCP | Text-to-speech voiceover |

### Knowledge & RAG
| Server | What It Does |
|--------|-------------|
| Memory (official) | Persistent knowledge graph across conversations |
| txtai MCP | Semantic search and knowledge graph |

---

## 3. Market Research: What Transcription Users Need

### Top Pain Points

1. **Manual follow-up work**: 1-2 hours daily syncing action items to task managers, CRMs, calendars. #1 complaint.
2. **Information silos**: Action items in one tool, notes in another, customer details in a third.
3. **No content repurposing**: Manually extracting quotes, creating show notes, drafting social posts.
4. **Rigid summary formats**: Users want customizable templates for different meeting types.
5. **No integration with existing workflows**: Most transcription apps are standalone.
6. **Privacy concerns**: Growing demand for local/on-device processing.

### Competitive Landscape

| App | Integrations | MCP? |
|-----|-------------|------|
| Otter.ai | Zoom, Google Meet, Salesforce | No |
| Fireflies.ai | Zapier, Salesforce, Asana, Slack | No |
| tl;dv | 6,000+ via APIs, CRM auto-fill | No |
| MacWhisper | None (standalone) | No |
| Claude Desktop | Full MCP support | Yes (but no transcription) |

**No transcription app currently offers MCP support.** Greenfield opportunity.

---

## 4. Top 10 MCP Use Cases — Prioritized

| Rank | Use Case | Demand | Effort | Differentiation | Score |
|------|----------|--------|--------|-----------------|-------|
| 1 | **Action items → task managers** (Todoist, Reminders) | Very High | Medium | High | 9.5 |
| 2 | **Meeting notes → Notion/Obsidian/Apple Notes** | Very High | Medium | High | 9.0 |
| 3 | **Calendar follow-up creation** (Apple Calendar) | High | Low | High | 8.5 |
| 4 | **Persistent knowledge base** (Memory server) | High | Medium | Very High | 8.5 |
| 5 | **Subtitle/SRT generation** in multiple formats | Medium-High | Low | Medium | 8.0 |
| 6 | **Web search for context enrichment** | Medium | Low | Medium | 7.5 |
| 7 | **Slack/email follow-up** after meetings | High | Medium | Medium | 7.5 |
| 8 | **Social media content** from transcripts | Medium | Medium | High | 7.0 |
| 9 | **File system read/write** for transcript management | Medium | Very Low | Low | 6.5 |
| 10 | **PDF export** of formatted transcripts | Medium | Low | Medium | 6.5 |

### Key Workflows

**Meeting Pipeline**: Transcribe → LLM extracts action items/decisions → MCP creates Todoist tasks + Notion page + Calendar follow-ups

**Podcast Production**: Transcribe → LLM generates show notes/quotes → MCP creates social posts + blog draft + PDF transcript

**Research Analysis**: Transcribe interviews → LLM identifies themes → MCP searches web for papers + saves to Obsidian

**Knowledge Building**: Transcribe over time → Memory server builds knowledge graph → "What did we decide about pricing in the last 3 meetings?"

---

## 5. Technical Implementation Plan

### Architecture

```
CTTranscriberApp
  ├── MCPClientManager (new)
  │     ├── discovers configured MCP servers
  │     ├── spawns stdio subprocesses or connects HTTP
  │     ├── maintains Client instances per server
  │     └── aggregates available tools across all servers
  ├── ChatViewModel (modified)
  │     ├── presents MCP tools to LLM in tool-call format
  │     ├── handles tool_use responses
  │     ├── calls MCPClientManager to execute tools
  │     └── renders tool results in chat UI
  └── SettingsView (modified)
        ├── MCP server configuration UI
        ├── server enable/disable toggles
        └── server health status
```

### Implementation Phases

| Phase | Scope | Effort |
|-------|-------|--------|
| **Phase 1 (MVP)** | MCP client infrastructure + settings UI + tool-call chat UI + filesystem server | 2-3 weeks |
| **Phase 2 (Core)** | Apple Calendar/Reminders + Apple Notes + subtitle generation | 1-2 weeks |
| **Phase 3 (Ecosystem)** | Notion, Todoist, Obsidian, Web Search, Slack | 1-2 weeks per integration |
| **Phase 4 (Advanced)** | Memory/Knowledge Base, Social Media, custom servers | Ongoing |

### Compatibility

- Swift SDK requires macOS 13.0+ — CT Transcriber targets 14.0+ ✅
- No app sandbox — subprocess spawning works ✅
- Async/await throughout — required by SDK ✅
- Multi-provider LLM support — both Anthropic and OpenAI APIs support tool use ✅

### Security

- Tool approval: require user confirmation for destructive tools (write, delete, send)
- Server trust: only run user-configured servers
- Subprocess isolation: each server in its own process
- Credentials: stored in macOS Keychain, passed via environment variables

---

## Sources

### MCP Protocol
- [MCP Specification (2025-11-25)](https://modelcontextprotocol.io/specification/2025-11-25)
- [Introducing MCP — Anthropic](https://www.anthropic.com/news/model-context-protocol)

### Swift SDK
- [Official MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)
- [Context — Native macOS MCP Client](https://github.com/indragiek/Context)

### Server Directories
- [mcpservers.org](https://mcpservers.org/)
- [Official MCP Registry](https://registry.modelcontextprotocol.io/)
- [punkpeye/awesome-mcp-servers](https://github.com/punkpeye/awesome-mcp-servers)

### Market Research
- [MacWhisper 12 — 9to5Mac](https://9to5mac.com/2025/03/18/macwhisper-12-delivers-the-most-requested-feature-to-the-leading-ai-transcription-app/)
- [Top AI Notetakers 2026 — AssemblyAI](https://www.assemblyai.com/blog/top-ai-notetakers)
- [Best Transcription Apps — Zapier](https://zapier.com/blog/best-transcription-apps/)

### Competitive Analysis
- [Claude Desktop MCP Setup](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop)
- [MCP in ChatGPT vs Claude — Dataslayer](https://www.dataslayer.ai/blog/mcp-in-claude-vs-chatgpt-vs-mistra)
