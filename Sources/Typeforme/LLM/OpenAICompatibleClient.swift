import Foundation

struct OpenAIChatMessage: Codable, Equatable, Sendable {
    let role: String
    let content: String
}

struct OpenAIChatTemplateKwargs: Codable, Equatable, Sendable {
    let enableThinking: Bool

    enum CodingKeys: String, CodingKey {
        case enableThinking = "enable_thinking"
    }
}

struct OpenAIChatCompletionRequest: Codable, Equatable, Sendable {
    let model: String
    let messages: [OpenAIChatMessage]
    let temperature: Double
    let topP: Double
    let topK: Int
    let minP: Double
    let presencePenalty: Double
    let repeatPenalty: Double
    let repetitionPenalty: Double
    let maxTokens: Int
    let stream: Bool
    let chatTemplateKwargs: OpenAIChatTemplateKwargs?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case minP = "min_p"
        case presencePenalty = "presence_penalty"
        case repeatPenalty = "repeat_penalty"
        case repetitionPenalty = "repetition_penalty"
        case maxTokens = "max_tokens"
        case stream
        case chatTemplateKwargs = "chat_template_kwargs"
    }
}

enum OpenAICompatibleClientError: LocalizedError, Equatable {
    case bodyEncode(String)
    case timeout
    case unavailable(String)
    case requestFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .bodyEncode(let detail):
            return "body encode: \(detail)"
        case .timeout:
            return "request timed out"
        case .unavailable(let detail):
            return detail
        case .requestFailed(let detail), .invalidResponse(let detail):
            return detail
        }
    }

    var correctorError: CorrectorError {
        switch self {
        case .timeout:
            return .timeout
        case .unavailable(let detail):
            return .unavailable(detail)
        case .bodyEncode(let detail), .requestFailed(let detail), .invalidResponse(let detail):
            return .requestFailed(detail)
        }
    }
}

enum OpenAICompatibleClient {
    /// Custom session: `waitsForConnectivity = true` so a transient OS-level
    /// "offline" reachability flag (e.g., during a Wi-Fi route flap) doesn't
    /// instantly reject a perfectly reachable LAN endpoint with
    /// NSURLErrorNotConnectedToInternet (-1009). With this flag, URLSession
    /// waits for the route to come back instead of throwing in ~3ms — at
    /// which point our higher-level timeoutMs still bounds the overall wait.
    /// `URLSession.shared` carries process-wide reachability state which is
    /// what was producing the false-positive offline rejections.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: config)
    }()

    static func chatCompletionContent(
        endpoint: URL,
        request body: OpenAIChatCompletionRequest,
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
        request.httpBody = bodyData
        request.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
        if let apiKey = normalizedAPIKey(apiKey) {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data = try await data(for: request, timeoutMs: timeoutMs, onTimeout: onTimeout)
        return try chatCompletionContent(from: data)
    }

    static func modelIDs(endpoint: URL, apiKey: String? = nil, timeout: TimeInterval = 5) async throws -> [String] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        if let apiKey = normalizedAPIKey(apiKey) {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let timeoutMs = max(1, Int((timeout * 1000).rounded()))
        let data = try await data(for: request, timeoutMs: timeoutMs, onTimeout: nil)
        return modelIDs(data: data)
    }

    static func modelIDs(data: Data) -> [String] {
        guard let response = try? BridgeJSON.decode(ModelsResponse.self, from: data) else {
            return []
        }
        return response.data.compactMap { model in
            let trimmed = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func data(
        for request: URLRequest,
        timeoutMs: Int,
        onTimeout: (@Sendable () async -> Void)?
    ) async throws -> Data {
        let completion = RequestCompletionFlag()
        let networkTask = Task<(Data, URLResponse), Error> {
            try await session.data(for: request)
        }
        let timeoutTask = Task<Void, Error> {
            try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            guard completion.tryComplete() else { return }
            networkTask.cancel()
            await onTimeout?()
        }
        defer {
            _ = completion.tryComplete()
            timeoutTask.cancel()
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await networkTask.value
        } catch is CancellationError {
            throw OpenAICompatibleClientError.timeout
        } catch let error as URLError where error.code == .cancelled {
            throw OpenAICompatibleClientError.timeout
        } catch {
            throw OpenAICompatibleClientError.unavailable(error.localizedDescription)
        }
        try validateHTTP(response, data: data)
        return data
    }

    private static func validateHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleClientError.invalidResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = errorMessage(data: data)
            throw OpenAICompatibleClientError.requestFailed("HTTP \(http.statusCode)\(detail.isEmpty ? "" : " \(detail)")")
        }
    }

    private static func chatCompletionContent(from data: Data) throws -> String {
        guard let response = try? BridgeJSON.decode(ChatCompletionResponse.self, from: data),
              let first = response.choices.first
        else {
            throw OpenAICompatibleClientError.invalidResponse("unexpected /v1/chat/completions response shape")
        }
        if let content = first.message?.content ?? first.text,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }
        if first.message?.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            throw OpenAICompatibleClientError.requestFailed("model returned reasoning without final content")
        }
        throw OpenAICompatibleClientError.invalidResponse("unexpected /v1/chat/completions response shape")
    }

    private static func normalizedAPIKey(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func errorMessage(data: Data) -> String {
        if let response = try? BridgeJSON.decode(ErrorResponse.self, from: data) {
            let message = response.error.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { return "server error message omitted (\(message.count) chars)" }
        }
        guard !data.isEmpty else { return "" }
        return "response body omitted (\(data.count) bytes)"
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            let reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
            }
        }

        let message: Message?
        let text: String?
    }

    let choices: [Choice]
}

private struct ModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

private struct ErrorResponse: Decodable {
    struct Payload: Decodable {
        let message: String
    }

    let error: Payload
}

private final class RequestCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func tryComplete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}
