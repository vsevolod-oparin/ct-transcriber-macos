import Foundation

// MARK: - Settings Model

struct AppSettings: Codable, Equatable {
    var general = GeneralSettings()
    var transcription = TranscriptionSettings()
    var llm = LLMSettings()
}

// MARK: - General

struct GeneralSettings: Codable, Equatable {
    enum AppTheme: String, Codable, CaseIterable {
        case system, light, dark
    }

    var theme: AppTheme = .system
}

// MARK: - Transcription

struct TranscriptionSettings: Codable, Equatable {
    enum WhisperModel: String, Codable, CaseIterable, Identifiable {
        case base = "whisper-base"
        case largeTurbo = "whisper-large-v3-turbo"
        case largeV3 = "whisper-large-v3"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .base: "Base (~150 MB)"
            case .largeTurbo: "Large V3 Turbo (~1.6 GB)"
            case .largeV3: "Large V3 (~3.1 GB)"
            }
        }
    }

    var model: WhisperModel = .largeTurbo
    var beamSize: Int = 5
    var temperature: Double = 0.0
    var language: String = "" // empty = auto-detect
    var vadFilter: Bool = true
    var conditionOnPreviousText: Bool = false
    var device: String = "mps" // "mps" or "cpu"

    var isValid: Bool {
        beamSize >= 1 && beamSize <= 20 && temperature >= 0.0 && temperature <= 2.0
    }
}

// MARK: - LLM

struct LLMSettings: Codable, Equatable {
    enum LLMProvider: String, Codable, CaseIterable, Identifiable {
        case openai = "OpenAI"
        case anthropic = "Anthropic"
        case deepseek = "DeepSeek"
        case qwen = "Qwen"

        var id: String { rawValue }

        var defaultBaseURL: String {
            switch self {
            case .openai: "https://api.openai.com"
            case .anthropic: "https://api.anthropic.com"
            case .deepseek: "https://api.deepseek.com"
            case .qwen: "https://dashscope.aliyuncs.com/compatible-mode"
            }
        }
    }

    var provider: LLMProvider = .openai
    var baseURL: String = LLMProvider.openai.defaultBaseURL
    var modelName: String = "gpt-4o-mini"
    var temperature: Double = 0.7
    var maxTokens: Int = 4096

    // API keys are NOT stored here — they go to Keychain
    // This field exists only for the Codable roundtrip to skip it
    var isValid: Bool {
        !modelName.isEmpty && temperature >= 0.0 && temperature <= 2.0 && maxTokens >= 1
    }
}
