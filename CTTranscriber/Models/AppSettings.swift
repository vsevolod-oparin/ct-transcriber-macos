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
