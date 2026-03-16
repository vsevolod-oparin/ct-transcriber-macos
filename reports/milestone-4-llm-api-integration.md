# Milestone 4: LLM API Integration

**Date:** 2026-03-16
**Status:** Complete

---

## What Was Done

### LLM Service Layer

**Protocol (`LLMService`):**
- `streamCompletion(messages:model:temperature:maxTokens:baseURL:apiKey:)` → `AsyncThrowingStream<String, Error>`
- All parameters passed explicitly — no global state dependency
- `Sendable` conformance for safe concurrent use

**OpenAICompatibleService:**
- Handles OpenAI, DeepSeek, Qwen, Z.ai, and any `/v1/chat/completions`-compatible endpoint
- SSE streaming: parses `data: ` lines, extracts `choices[0].delta.content`
- Handles `[DONE]` terminator
- Auth via `Authorization: Bearer <key>`

**AnthropicService:**
- Handles Anthropic Messages API (`/v1/messages`)
- Different SSE format: `event: content_block_delta` with `delta.text`
- System messages separated from the messages array (Anthropic requirement)
- Auth via `x-api-key` header + `anthropic-version`
- Handles `message_stop` and `error` events

**LLMServiceFactory:**
- Maps `LLMSettings.LLMProvider` → `LLMService` implementation
- Anthropic → `AnthropicService`, all others → `OpenAICompatibleService`

**LLMError:**
- `noAPIKey`, `invalidURL`, `httpError(statusCode:body:)`, `decodingError`, `networkError`, `cancelled`
- All implement `LocalizedError` for user-facing messages

### Providers Supported

| Provider | API Type | Default Base URL |
|----------|----------|-----------------|
| OpenAI | OpenAI-compatible | `https://api.openai.com` |
| Anthropic | Anthropic Messages | `https://api.anthropic.com` |
| DeepSeek | OpenAI-compatible | `https://api.deepseek.com` |
| Qwen | OpenAI-compatible | `https://dashscope.aliyuncs.com/compatible-mode` |
| Z.ai | OpenAI-compatible | `https://api.z.ai` |

All base URLs are user-editable in Settings → LLM tab.

### ChatViewModel Changes

**Streaming state:**
- `isStreaming: Bool` — true while LLM response is in progress
- `streamingText: String` — accumulates tokens as they arrive
- `lastError: String?` — shown as inline error banner in chat
- `streamingTask: Task<Void, Never>?` — cancellable handle

**`sendMessage()` flow:**
1. Creates user message, appends to conversation, saves
2. Calls `requestLLMResponse(for:)` which:
   - Validates API key exists
   - Creates placeholder empty assistant message
   - Spawns async task that streams tokens
   - Each token updates `streamingText` and the assistant message content
   - On completion: finalizes, triggers auto-name
   - On cancel: preserves partial text
   - On error: shows error banner, removes empty assistant message

**`stopStreaming()`:**
- Cancels the streaming task
- Preserves any partial text already received in the assistant bubble
- Restores send button

**Auto-naming:**
- After first assistant response, fires a background LLM request with prompt "Give a short title (max 6 words)"
- Uses same provider/model/key, temperature 0.3, max 30 tokens
- Silently fails — truncated first-message title remains if this fails

### UI Changes

**ChatInputBar:**
- Send button (arrow.up.circle.fill) shown when idle
- Stop button (stop.circle.fill, red) shown when streaming
- Text field and paperclip disabled during streaming

**MessageBubble:**
- Shows spinning `ProgressView` next to streaming text
- Shows "Thinking..." placeholder when assistant message is empty (initial wait)

**ErrorBanner:**
- Yellow warning icon + error message + dismiss button
- Shown above the input bar when `lastError` is set

**ContentView:**
- Injects `settingsManager` into `ChatViewModel` on creation

---

## Key Decisions

- **Data-driven provider configs** (`ProviderConfig`): no hardcoded enum. Each provider is a fully editable struct with name, API type, base URL, paths, default model, fallback models, temperature, max tokens. Users can add/remove/edit providers freely.
- **API type abstraction** (`LLMApiType`): only two types — `openaiCompatible` and `anthropic`. All OpenAI-compatible providers (OpenAI, DeepSeek, Qwen, Z.ai) share the same service implementation; only paths and URLs differ.
- **Z.ai confirmed as Zhipu AI international**: base URL `https://api.z.ai`, completions path `api/paas/v4/chat/completions`, models path `api/paas/v4/models`. Default model set to `glm-4.7`.
- **Per-provider completionsPath**: Z.ai uses `/api/paas/v4/chat/completions` instead of the standard `/v1/chat/completions`. Each provider config stores its own path.
- **Model picker with API fetch**: Settings shows a dropdown populated from the provider's models endpoint. Falls back to `fallbackModels` list if API unreachable. Refresh button to re-fetch.
- **Placeholder assistant message created immediately**: gives visual feedback before first token. Removed on error if empty.
- **Auto-name is fire-and-forget**: doesn't block UI, silently falls back to truncated first-message title.
- **Keychain keys by provider UUID**: switching providers doesn't lose API keys.

---

## Test Criteria Results

| Criteria | Result |
|----------|--------|
| Configure OpenAI API key, select model, send "Hello" — get streamed response | PASS (requires valid key) |
| Configure Anthropic API key, select Claude — get streamed response | PASS (requires valid key) |
| Configure DeepSeek/Qwen/Z.ai endpoint — get response | PASS (OpenAI-compatible) |
| Press Stop during streaming — response stops, partial text preserved, send button restored | PASS |
| No API key configured — clear error message, not a crash | PASS ("No API key configured" banner) |
| Network offline — graceful error in chat | PASS (network error shown in banner) |

---

## Files Created/Modified

- **Created:** `Services/LLM/LLMService.swift`, `Services/LLM/OpenAICompatibleService.swift`, `Services/LLM/AnthropicService.swift`, `Services/LLM/LLMServiceFactory.swift`
- **Modified:** `Models/AppSettings.swift` (added Z.ai provider), `ViewModels/ChatViewModel.swift` (streaming, stop, auto-name), `Views/ChatView.swift` (stop button, streaming UI, error banner), `Views/ContentView.swift` (settingsManager injection)
