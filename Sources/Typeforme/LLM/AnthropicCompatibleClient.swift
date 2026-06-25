import Foundation

struct AnthropicMessage: Codable, Equatable, Sendable {
    let role: String
    let content: String
}

struct AnthropicMessagesRequest: Codable, Equatable, Sendable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [AnthropicMessage]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

enum AnthropicCompatibleClient {
    static let apiVersion = "2023-06-01"

    static func messageContent(
        endpoint: URL,
        request body: AnthropicMessagesRequest,
        apiKey: String? = nil,
        timeoutMs: Int,
        onTimeout: (@Sendable () async -> Void)? = nil
    ) async throws -> String {
        let bodyData: Data
        do {
            bodyData = try BridgeJSON.encode(body)
        } catch {
            throw OpenAICompatibleClientError.bodyEncode(error.localizedDescription)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData
        request.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
        if let apiKey = normalizedAPIKey(apiKey) {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        let data = try await OpenAICompatibleClient.responseData(
            for: request,
            timeoutMs: timeoutMs,
            onTimeout: onTimeout
        )
        return try messageContent(from: data)
    }

    static func modelIDs(endpoint: URL, apiKey: String? = nil, timeout: TimeInterval = 5) async throws -> [String] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = timeout
        if let apiKey = normalizedAPIKey(apiKey) {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        let timeoutMs = max(1, Int((timeout * 1000).rounded()))
        let data = try await OpenAICompatibleClient.responseData(for: request, timeoutMs: timeoutMs, onTimeout: nil)
        return try modelIDs(data: data)
    }

    static func modelIDs(data: Data) throws -> [String] {
        do {
            let response = try BridgeJSON.decode(ModelsResponse.self, from: data)
            return response.data.compactMap { model in
                let trimmed = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        } catch {
            throw OpenAICompatibleClientError.invalidResponse("unexpected /v1/models response shape")
        }
    }

    static func messageContent(from data: Data) throws -> String {
        guard let response = try? BridgeJSON.decode(MessagesResponse.self, from: data) else {
            throw OpenAICompatibleClientError.invalidResponse("unexpected /v1/messages response shape")
        }
        let content = response.content
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw OpenAICompatibleClientError.invalidResponse("unexpected /v1/messages response shape")
        }
        return content
    }

    private static func normalizedAPIKey(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct MessagesResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String?
        let text: String?
    }

    let content: [ContentBlock]
}

private struct ModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}
