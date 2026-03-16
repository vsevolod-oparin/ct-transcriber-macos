import Foundation

enum LLMServiceFactory {
    static func service(for provider: ProviderConfig) -> LLMService {
        switch provider.apiType {
        case .anthropic:
            AnthropicService()
        case .openaiCompatible:
            OpenAICompatibleService()
        }
    }
}
