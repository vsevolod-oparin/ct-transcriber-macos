import Foundation

// MARK: - Chat Message DTO

struct ChatMessageDTO {
    let role: String // "user", "assistant", "system"
    let content: String
}

// MARK: - LLM Errors

enum LLMError: LocalizedError {
    case noAPIKey
    case invalidURL
    case httpError(statusCode: Int, body: String)
    case decodingError(String)
    case networkError(Error)
    case cancelled

    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            "No API key configured. Open Settings (⌘,) to add one."
        case .invalidURL:
            "Invalid API base URL."
        case .httpError(let code, let body):
            "API error (\(code)): \(body)"
        case .decodingError(let detail):
            "Failed to parse response: \(detail)"
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .cancelled:
            "Request cancelled."
        }
    }
}

// MARK: - Shared URLSession

/// URLSession with timeouts configured for LLM streaming.
let llmURLSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    config.timeoutIntervalForResource = 600 // 10 min max for long responses
    return URLSession(configuration: config)
}()

// MARK: - LLM Service Protocol

protocol LLMService: Sendable {
    func streamCompletion(
        messages: [ChatMessageDTO],
        model: String,
        temperature: Double,
        maxTokens: Int,
        baseURL: String,
        completionsPath: String,
        apiKey: String,
        extraHeaders: [String: String]
    ) -> AsyncThrowingStream<String, Error>
}
