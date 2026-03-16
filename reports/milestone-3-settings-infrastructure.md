# Milestone 3: Settings Infrastructure

**Date:** 2026-03-16
**Status:** Complete

---

## What Was Done

### Settings Model (`AppSettings`)

Three nested Codable structs:

**GeneralSettings:**
- `theme`: system/light/dark (applied via `preferredColorScheme`)

**TranscriptionSettings:**
- `model`: enum of Whisper models (base, large-v3-turbo, large-v3) with display names and sizes
- `beamSize`: 1–20 (default 5)
- `temperature`: 0.0–2.0 (default 0.0)
- `language`: empty = auto-detect
- `vadFilter`: default true
- `conditionOnPreviousText`: default false
- `device`: "mps" or "cpu" (default "mps")
- `isValid` computed property for validation

**LLMSettings:**
- `provider`: enum (OpenAI, Anthropic, DeepSeek, Qwen) with default base URLs
- `baseURL`: editable, pre-filled from provider default
- `modelName`: default "gpt-4o-mini"
- `temperature`: 0.0–2.0 (default 0.7)
- `maxTokens`: default 4096
- API keys are NOT in this struct — stored in Keychain

### Persistence

**SettingsStorage:**
- JSON file at `~/.config/ct-transcriber/settings.json`
- Pretty-printed with sorted keys (human-readable)
- Graceful fallback to defaults on missing/corrupted file
- Directory created lazily on first save
- File only written when settings change (no empty default file)

**KeychainService:**
- Stores API keys in macOS Keychain under service `com.branch.ct-transcriber`
- Key per provider: `apikey-OpenAI`, `apikey-Anthropic`, etc.
- `save`, `load`, `delete` operations
- Secure — keys never touch disk in plaintext

### SettingsManager (`@Observable`)

- Loads settings on init from JSON
- Auto-saves on change via `didSet`
- `apiKey(for:)` / `setApiKey(_:for:)` — Keychain-backed
- `colorScheme` computed property for theme application
- Injected into environment at app level

### Settings UI (`SettingsView`)

Three-tab `TabView` (480x380):

- **General**: theme picker (segmented: System/Light/Dark)
- **Transcription**: model picker, device picker, beam size (stepper + text field), temperature, language, VAD toggle, condition toggle. Validation errors shown in red.
- **LLM**: provider picker (auto-fills base URL), base URL field, SecureField for API key (Keychain-backed), model name, temperature, max tokens. Validation errors shown in red.

### App Integration

- `SettingsManager` created as `@State` in `CTTranscriberApp`
- Injected into `ContentView` via `.environment()`
- Theme applied via `.preferredColorScheme(settingsManager.colorScheme)`
- Settings scene uses `SettingsView(settingsManager:)`
- Accessible via `Cmd+,`

---

## Key Decisions

- **JSON at `~/.config/` rather than `~/Library/Preferences/`**: matches RFC spec, XDG-compatible, human-editable. macOS convention would be `UserDefaults` plist, but JSON is more portable and inspectable.
- **Keychain for API keys**: never stored in JSON. Per-provider keys so switching providers doesn't lose keys.
- **Settings file lazy creation**: no file written until user changes something. Avoids cluttering the filesystem with defaults.
- **Provider base URL editable**: allows pointing DeepSeek/Qwen at custom endpoints or proxies.
- **Validation inline** (red text below invalid fields) rather than blocking save: settings always save, but `isValid` can be checked before use in M4/M7.

---

## Test Criteria Results

| Criteria | Result |
|----------|--------|
| Open Settings, change transcription beam size, close and reopen — value persists | PASS |
| API key saved to Keychain, retrievable after app restart | PASS |
| Invalid settings (e.g., beam size = 0) show validation error | PASS |
| Settings JSON file is human-readable at expected path | PASS |

---

## Files Created/Modified

- **Created:** `Models/AppSettings.swift`, `Services/KeychainService.swift`, `Services/SettingsStorage.swift`, `ViewModels/SettingsManager.swift`, `Views/SettingsView.swift`
- **Modified:** `App/CTTranscriberApp.swift` (SettingsManager injection, theme, SettingsView)
