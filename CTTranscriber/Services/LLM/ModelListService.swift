import Foundation

enum ModelListService {

    /// Fetches available model IDs from the provider's models endpoint.
    /// Returns fallback models on any failure.
    static func fetchModels(
        provider: ProviderConfig,
        apiKey: String
    ) async -> [String] {
        guard !provider.modelsPath.isEmpty,
              let url = URL(string: provider.baseURL)?.appendingPathComponent(provider.modelsPath) else {
            return provider.fallbackModels
        }

        guard !apiKey.isEmpty else {
            return provider.fallbackModels
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return provider.fallbackModels
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else {
                return provider.fallbackModels
            }

            let modelIDs = models.compactMap { $0["id"] as? String }.sorted()
            return modelIDs.isEmpty ? provider.fallbackModels : modelIDs
        } catch {
            return provider.fallbackModels
        }
    }
}
