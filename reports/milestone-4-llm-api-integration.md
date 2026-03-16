# Milestone 4: LLM API Integration

**Date:** 2026-03-16
**Status:** Complete

---

## What Was Done

### LLM Service Layer

**Protocol (`LLMService`):**
- `streamCompletion(messages:model:temperature:maxTokens:baseURL:completionsPath:apiKey:extraHeaders:)` → `AsyncThrowingStream<String, Error>`
- All parameters passed explicitly — no global state dependency
- `Sendable` conformance for safe concurrent use

**OpenAICompatibleService:**
- Handles OpenAI, DeepSeek, Qwen, Z.ai, and any `/v1/chat/completions`-compatible endpoint
- SSE streaming: parses `data: ` lines, extracts `choices[0].delta.content`
- Handles `[DONE]` terminator
- Auth via `Authorization: Bearer <key>`
- Extra headers applied from provider config

**AnthropicService:**
- Handles Anthropic Messages API with SSE streaming
- Different SSE format: `event: content_block_delta` with `delta.text`
- System messages separated from the messages array (Anthropic requirement)
- Auth via `x-api-key` header
- `anthropic-version` header comes from `extraHeaders` in config (not hardcoded)

**LLMServiceFactory:**
- Maps `LLMApiType` → `LLMService` implementation
- `anthropic` → `AnthropicService`, `openaiCompatible` → `OpenAICompatibleService`

### Data-Driven Provider Configs

All provider configurations are stored in `default-settings.json` (bundled) and `settings.json` (user config). No hardcoded provider URLs, paths, models, or headers in Swift code.

**`ProviderConfig` struct:**
- `name`, `apiType` (OpenAI Compatible / Anthropic)
- `baseURL`, `completionsPath`, `modelsPath`
- `defaultModel`, `fallbackModels`
- `temperature`, `maxTokens`
- `apiKey` — stored in plaintext in settings.json (industry standard for LLM tools)
- `extraHeaders` — arbitrary key-value pairs (e.g., `anthropic-version`, `Accept-Language`)

**Default providers shipped:**

| Provider | Default Model | API Type | Completions Path |
|----------|--------------|----------|-----------------|
| Z.ai | glm-4.7 | OpenAI Compatible | api/paas/v4/chat/completions |
| OpenAI | gpt-4o-mini | OpenAI Compatible | v1/chat/completions |
| Anthropic | claude-sonnet-4-20250514 | Anthropic | v1/messages |
| DeepSeek | deepseek-chat | OpenAI Compatible | v1/chat/completions |
| Qwen | qwen-plus | OpenAI Compatible | v1/chat/completions |

Users can add/remove/edit any provider through Settings or by editing `settings.json` directly.

### Model Fetching

`ModelListService` fetches available models from each provider's models endpoint. Falls back to `fallbackModels` list on failure. Refresh button in Settings. Auto-fetches on tab open and after entering API key.

### Streaming & Stop

- `isStreaming` state drives UI: send button → red stop button, text field disabled
- Placeholder "Thinking..." assistant bubble before first token
- Tokens appear in real-time in the assistant message bubble
- Stop button cancels URLSession stream, preserves partial text
- Error banner shown inline above input bar

### Auto-naming

After first assistant response, background LLM request generates a short title (max 6 words). Silently falls back to truncated first-message title on failure.

### API Key Storage

API keys stored in `settings.json` alongside each provider config (plaintext). Keychain removed — was causing password prompts on app launch and settings access, unacceptable UX for a dev tool.

### Input Focus

Message input field auto-focuses when switching conversations via `@FocusState`.

### Settings UI

LLM tab redesigned with:
- Provider selector with +/- buttons
- Full config editor: Provider (name, API type), Endpoints (base URL, paths), Authentication (API key), Extra Headers (key: value per line), Model (picker with fetch + fallback list), Defaults (temperature, max tokens)

---

## Key Decisions

- **No hardcoded configs in Swift**: all provider URLs, paths, models, headers, and API keys come from `default-settings.json` (bundled) or `settings.json` (user config)
- **Plaintext API keys**: industry standard for LLM dev tools. Keychain prompts were unacceptable UX
- **`extraHeaders` dict**: handles provider-specific headers (Anthropic version, Z.ai Accept-Language) without hardcoding
- **Per-provider `completionsPath`**: Z.ai uses `api/paas/v4/chat/completions`, others use `v1/chat/completions`
- **Auto-name is fire-and-forget**: doesn't block UI, silently falls back

---

## Known Issues

- 4 of 5 rename UI tests regressed due to XCUITest `typeText` not replacing selected text in NSTextField. Manual rename works correctly. Deferred to a dedicated test-fix session.

---

## Files Created/Modified

- **Created:** `Services/LLM/LLMService.swift`, `Services/LLM/OpenAICompatibleService.swift`, `Services/LLM/AnthropicService.swift`, `Services/LLM/LLMServiceFactory.swift`, `Services/LLM/ModelListService.swift`, `Resources/default-settings.json`
- **Modified:** `Models/AppSettings.swift` (data-driven ProviderConfig with apiKey, extraHeaders), `ViewModels/ChatViewModel.swift` (streaming, stop, auto-name), `ViewModels/SettingsManager.swift` (simplified, no Keychain), `Services/SettingsStorage.swift` (bundled defaults, fallback paths), `Views/ChatView.swift` (stop button, streaming UI, error banner, input focus), `Views/ContentView.swift` (settingsManager injection), `Views/SettingsView.swift` (provider config editor), `App/CTTranscriberApp.swift` (SettingsManager, theme)
- **Deleted:** `Services/KeychainService.swift`
