import Foundation

/// Handles the Anthropic Messages API (/v1/messages) with SSE streaming.
/// Different request/response format from OpenAI.
struct AnthropicService: LLMService {

    func streamCompletion(
        messages: [ChatMessageDTO],
        model: String,
        temperature: Double,
        maxTokens: Int,
        baseURL: String,
        completionsPath: String,
        apiKey: String,
        extraHeaders: [String: String]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: baseURL)?
                        .appendingPathComponent(completionsPath) else {
                        throw LLMError.invalidURL
                    }

                    // Anthropic separates system messages from the messages array
                    let systemMessage = messages.first { $0.role == "system" }?.content
                    let chatMessages = messages.filter { $0.role != "system" }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    if extraHeaders["anthropic-version"] == nil {
                        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    }
                    for (key, value) in extraHeaders {
                        request.setValue(value, forHTTPHeaderField: key)
                    }

                    var body: [String: Any] = [
                        "model": model,
                        "messages": chatMessages.map { ["role": $0.role, "content": $0.content] },
                        "max_tokens": maxTokens,
                        "temperature": temperature,
                        "stream": true,
                    ]
                    if let system = systemMessage {
                        body["system"] = system
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await llmURLSession.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw LLMError.networkError(URLError(.badServerResponse))
                    }

                    if httpResponse.statusCode != 200 {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                        }
                        throw LLMError.httpError(statusCode: httpResponse.statusCode, body: errorBody)
                    }

                    // Anthropic SSE format:
                    //   event: content_block_delta
                    //   data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }

                        let eventType = json["type"] as? String

                        if eventType == "content_block_delta",
                           let delta = json["delta"] as? [String: Any],
                           let text = delta["text"] as? String {
                            continuation.yield(text)
                        }

                        if eventType == "message_stop" {
                            break
                        }

                        // Handle error events
                        if eventType == "error",
                           let error = json["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            throw LLMError.httpError(statusCode: 0, body: message)
                        }
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch let error as LLMError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: LLMError.networkError(error))
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
