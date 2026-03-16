import Foundation

// MARK: - Settings Model

struct AppSettings: Codable, Equatable {
    var general: GeneralSettings
    var transcription: TranscriptionSettings
    var llm: LLMSettings
}

// MARK: - General

struct GeneralSettings: Codable, Equatable {
    enum AppTheme: String, Codable, CaseIterable {
        case system, light, dark
    }

    var theme: AppTheme = .system
}

// MARK: - Transcription

/// A Whisper model available for download and conversion.
struct WhisperModelConfig: Codable, Equatable, Identifiable {
    var id: String          // e.g. "whisper-large-v3-turbo"
    var huggingFaceID: String // e.g. "openai/whisper-large-v3-turbo"
    var displayName: String
    var sizeEstimate: String  // e.g. "~1.6 GB"
    var quantization: String  // e.g. "float16"
}

struct TranscriptionSettings: Codable, Equatable {
    /// Conda environment name for whisper-metal.
    var condaEnvName: String
    /// Path to CTranslate2 source directory (for source builds; empty = use pre-built wheel).
    var ctranslate2SourcePath: String
    /// URL to pre-built CTranslate2 Metal package (tar.gz with wheel + dylib).
    var ct2PackageURL: String
    /// Path to directory where converted whisper models are stored.
    var modelsDirectory: String
    /// Currently selected model ID for transcription.
    var selectedModelID: String
    /// Available whisper models (editable in settings.json).
    var models: [WhisperModelConfig]

    var beamSize: Int
    var temperature: Double
    var language: String // empty = auto-detect
    var vadFilter: Bool
    var conditionOnPreviousText: Bool
    var device: String // "mps" or "cpu"

    var isValid: Bool {
        beamSize >= 1 && beamSize <= 20 && temperature >= 0.0 && temperature <= 2.0
    }

    var selectedModel: WhisperModelConfig? {
        models.first { $0.id == selectedModelID }
    }
}

// MARK: - LLM

/// API protocol type — determines request/response format.
enum LLMApiType: String, Codable, CaseIterable, Identifiable {
    case openaiCompatible = "OpenAI Compatible"
    case anthropic = "Anthropic"

    var id: String { rawValue }
}

/// A single LLM provider configuration — fully user-editable.
struct ProviderConfig: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var apiType: LLMApiType
    var baseURL: String
    var completionsPath: String
    var modelsPath: String
    var defaultModel: String
    var fallbackModels: [String]
    var temperature: Double
    var maxTokens: Int
    /// API key for this provider. Stored in settings.json (plaintext, same as industry standard for LLM tools).
    var apiKey: String
    /// Additional HTTP headers sent with every request (e.g., {"anthropic-version": "2023-06-01"}).
    var extraHeaders: [String: String]

    var isValid: Bool {
        !name.isEmpty && !baseURL.isEmpty && !completionsPath.isEmpty && !defaultModel.isEmpty
            && temperature >= 0.0 && temperature <= 2.0 && maxTokens >= 1
    }
}

struct LLMSettings: Codable, Equatable {
    var activeProviderID: UUID
    var providers: [ProviderConfig]

    var activeProvider: ProviderConfig? {
        providers.first { $0.id == activeProviderID }
    }

    var isValid: Bool {
        activeProvider?.isValid ?? false
    }
}
