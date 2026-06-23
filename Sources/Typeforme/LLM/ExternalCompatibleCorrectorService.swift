import Foundation

struct ExternalLLMCheckReport: Sendable {
    let ok: Bool
    let status: String
    let detail: String
    let modelIDs: [String]
}

typealias ExternalLLMModelIDFetcher = @Sendable (
    _ apiKind: ExternalLLMAPIKind,
    _ endpoint: URL,
    _ apiKey: String?,
    _ timeout: TimeInterval
) async throws -> [String]

enum ExternalLLMAPIKind: Sendable {
    case openAI
    case anthropic

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI-compatible"
        case .anthropic: return "Anthropic-compatible"
        }
    }

    var completionPath: String {
        switch self {
        case .openAI: return "/chat/completions"
        case .anthropic: return "/messages"
        }
    }
}

final class ExternalCompatibleCorrectorService: CorrectorService {
    let kind: CorrectionBackendKind

    static let minimumRequestTimeoutMs = 100
    private static let configurationCheckTimeout: TimeInterval = 5
    private static let invalidAPIKeyProbePrefix = "typeforme-invalid-external-llm-token-"

    init(kind: CorrectionBackendKind) {
        self.kind = kind
    }

    func correct(_ request: CorrectionRequest, timeoutMs: Int) async throws -> CorrectionResult {
        let (system, user) = PromptBuilder.build(for: request)
        let content = try await complete(system: system, user: user, timeoutMs: timeoutMs)
        do {
            var result = try CorrectionValidator.parseAndValidate(rawOutput: content, for: request)
            result.text = ProtectedSpanPostProcessor.apply(result.text, rawTranscript: request.transcriptEvidenceText)
            result.text = TranscriptPostProcessor.clean(
                result.text,
                languageIDs: request.languageIDs,
                preserveLineBreaks: request.correctionMode == .structurePlus,
                numberPreference: request.numberOutputPreference,
                punctuationPreference: request.punctuationPreference
            )
            return result
        } catch let error as CorrectionValidationError {
            throw CorrectorError.validationFailed(error.localizedDescription)
        }
    }

    func complete(system: String, user: String, timeoutMs: Int) async throws -> String {
        let model = AppSettings.externalLLMModel
        guard !model.isEmpty else {
            throw CorrectorError.unavailable("Set the external model identifier in Settings")
        }

        let apiKind = try Self.apiKind(for: kind)
        let endpoint = try Self.completionsEndpoint(baseURL: AppSettings.externalLLMBaseURL, apiKind: apiKind)
        let requestTimeoutMs = Self.effectiveTimeoutMs(timeoutMs)

        do {
            switch apiKind {
            case .openAI:
                let body = CorrectorChatRequestBuilder.body(
                    model: model,
                    system: system,
                    user: user,
                    maxTokens: AppSettings.correctionMaxTokens,
                    baseURL: AppSettings.externalLLMBaseURL
                )
                return try await OpenAICompatibleClient.chatCompletionContent(
                    endpoint: endpoint,
                    request: body,
                    apiKey: AppSettings.externalLLMAPIKey,
                    timeoutMs: requestTimeoutMs
                )
            case .anthropic:
                let body = AnthropicMessagesRequest(
                    model: model,
                    maxTokens: AppSettings.correctionMaxTokens,
                    system: system,
                    messages: [AnthropicMessage(role: "user", content: user)]
                )
                return try await AnthropicCompatibleClient.messageContent(
                    endpoint: endpoint,
                    request: body,
                    apiKey: AppSettings.externalLLMAPIKey,
                    timeoutMs: requestTimeoutMs
                )
            }
        } catch let error as OpenAICompatibleClientError {
            throw error.correctorError
        }
    }

    static func effectiveTimeoutMs(_ configuredTimeoutMs: Int) -> Int {
        max(configuredTimeoutMs, minimumRequestTimeoutMs)
    }

    static func checkConfiguration(
        apiKind: ExternalLLMAPIKind,
        baseURL: String = AppSettings.externalLLMBaseURL,
        apiKey: String = AppSettings.externalLLMAPIKey,
        selectedModel: String = AppSettings.externalLLMModel,
        modelIDFetcher: ExternalLLMModelIDFetcher? = nil
    ) async -> ExternalLLMCheckReport {
        let trimmedAPIKey = normalizedAPIKey(apiKey)
        let fetchModelIDs = modelIDFetcher ?? defaultModelIDFetcher
        do {
            let endpoint = try modelsEndpoint(baseURL: baseURL, apiKind: apiKind)
            let modelIDs = try await fetchModelIDs(apiKind, endpoint, trimmedAPIKey, configurationCheckTimeout)
            if trimmedAPIKey != nil,
               let verificationFailure = await apiKeyVerificationFailureReport(
                apiKind: apiKind,
                endpoint: endpoint,
                modelIDs: modelIDs,
                modelIDFetcher: fetchModelIDs
               ) {
                return verificationFailure
            }
            let report = availabilityReport(modelIDs: modelIDs, selectedModel: selectedModel, apiKind: apiKind)
            return trimmedAPIKey == nil ? report : report.withDetailPrefix("API key verified.")
        } catch let error as OpenAICompatibleClientError where error.isAuthenticationFailure {
            let detail = trimmedAPIKey == nil
                ? "\(apiKind.displayName) server requires an API key. Enter a valid API token."
                : "\(apiKind.displayName) server rejected the API key. Check the token and its permissions."
            return ExternalLLMCheckReport(ok: false, status: "Failed", detail: detail, modelIDs: [])
        } catch {
            return ExternalLLMCheckReport(ok: false, status: "Failed", detail: error.localizedDescription, modelIDs: [])
        }
    }

    static func apiKind(for backend: CorrectionBackendKind) throws -> ExternalLLMAPIKind {
        switch backend {
        case .externalOpenAICompatible:
            return .openAI
        case .externalAnthropicCompatible:
            return .anthropic
        case .qwen35_2B, .qwen35_4B, .qwen35_9B:
            throw CorrectorError.unavailable("Selected backend is not an external compatible API")
        }
    }

    static func completionsEndpoint(baseURL: String, apiKind: ExternalLLMAPIKind) throws -> URL {
        try compatibleEndpoint(baseURL: baseURL, path: apiKind.completionPath)
    }

    static func modelsEndpoint(baseURL: String, apiKind: ExternalLLMAPIKind) throws -> URL {
        try compatibleEndpoint(baseURL: baseURL, path: "/models")
    }

    private static func compatibleEndpoint(baseURL: String, path: String) throws -> URL {
        let normalized = try compatibleBaseURLString(baseURL)
        guard let url = URL(string: normalized + path) else {
            throw CorrectorError.unavailable("Invalid external LLM URL")
        }
        try validateHTTPURL(url)
        return url
    }

    private static func compatibleBaseURLString(_ baseURL: String) throws -> String {
        let normalized = normalizedBaseURLString(baseURL)
        guard !normalized.isEmpty else {
            throw CorrectorError.unavailable("External LLM URL is empty")
        }
        guard var components = URLComponents(string: normalized) else {
            throw CorrectorError.unavailable("Invalid external LLM URL")
        }
        components.query = nil
        components.fragment = nil
        var path = components.percentEncodedPath
        for suffix in ["/chat/completions", "/messages", "/models"] where path.hasSuffix(suffix) {
            path = String(path.dropLast(suffix.count))
        }
        if path.isEmpty {
            path = "/v1"
        } else if !path.hasSuffix("/v1") {
            path += "/v1"
        }
        components.percentEncodedPath = path
        guard let url = components.url else { throw CorrectorError.unavailable("Invalid external LLM URL") }
        try validateHTTPURL(url)
        return url.absoluteString
    }

    private static func validateHTTPURL(_ url: URL) throws {
        guard
            let scheme = url.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            url.host != nil
        else {
            throw CorrectorError.unavailable("External LLM URL must be an http or https URL")
        }
    }

    static func modelIDs(data: Data, apiKind: ExternalLLMAPIKind) -> [String] {
        switch apiKind {
        case .openAI:
            return OpenAICompatibleClient.modelIDs(data: data)
        case .anthropic:
            return AnthropicCompatibleClient.modelIDs(data: data)
        }
    }

    static func modelSelectionAfterRefresh(
        current: String,
        available: [String],
        selectFirstModel: Bool
    ) -> String {
        let trimmedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = available.first else {
            return trimmedCurrent
        }
        guard !trimmedCurrent.isEmpty else {
            return selectFirstModel ? first : trimmedCurrent
        }
        return available.contains(trimmedCurrent) ? trimmedCurrent : first
    }

    static func availabilityReport(
        modelIDs: [String],
        selectedModel: String,
        apiKind: ExternalLLMAPIKind
    ) -> ExternalLLMCheckReport {
        let selected = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelIDs.isEmpty else {
            let hint = selected.isEmpty
                ? "Load or enter a model before using correction."
                : "Load or enter \(selected) before using correction."
            return ExternalLLMCheckReport(
                ok: false,
                status: "Failed",
                detail: "\(apiKind.displayName) server is reachable, but no models are listed. \(hint)",
                modelIDs: []
            )
        }
        guard selected.isEmpty || modelIDs.contains(selected) else {
            return ExternalLLMCheckReport(
                ok: true,
                status: "Ready",
                detail: "Selected model \(selected) is not listed. Select a listed model. \(modelListSummary(modelIDs: modelIDs))",
                modelIDs: modelIDs
            )
        }
        return ExternalLLMCheckReport(
            ok: true,
            status: "Ready",
            detail: modelListSummary(modelIDs: modelIDs),
            modelIDs: modelIDs
        )
    }

    private static func modelListSummary(modelIDs: [String]) -> String {
        let preview = modelIDs.prefix(4).joined(separator: ", ")
        return modelIDs.count > 4 ? "\(modelIDs.count) models: \(preview), ..." : "\(modelIDs.count) models: \(preview)"
    }

    private static let defaultModelIDFetcher: ExternalLLMModelIDFetcher = { apiKind, endpoint, apiKey, timeout in
        switch apiKind {
        case .openAI:
            return try await OpenAICompatibleClient.modelIDs(endpoint: endpoint, apiKey: apiKey, timeout: timeout)
        case .anthropic:
            return try await AnthropicCompatibleClient.modelIDs(endpoint: endpoint, apiKey: apiKey, timeout: timeout)
        }
    }

    private static func apiKeyVerificationFailureReport(
        apiKind: ExternalLLMAPIKind,
        endpoint: URL,
        modelIDs: [String],
        modelIDFetcher: ExternalLLMModelIDFetcher
    ) async -> ExternalLLMCheckReport? {
        do {
            _ = try await modelIDFetcher(apiKind, endpoint, invalidAPIKeyProbe(), configurationCheckTimeout)
            return ExternalLLMCheckReport(
                ok: false,
                status: "Failed",
                detail: "\(apiKind.displayName) server accepted a deliberately invalid API key. Enable authentication on the server, then refresh models to verify the configured key.",
                modelIDs: modelIDs
            )
        } catch let error as OpenAICompatibleClientError where error.isAuthenticationFailure {
            return nil
        } catch {
            return ExternalLLMCheckReport(
                ok: false,
                status: "Failed",
                detail: "Could not verify that \(apiKind.displayName) rejects invalid API keys: \(error.localizedDescription)",
                modelIDs: modelIDs
            )
        }
    }

    private static func invalidAPIKeyProbe() -> String {
        invalidAPIKeyProbePrefix + UUID().uuidString
    }

    private static func normalizedAPIKey(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedBaseURLString(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private extension ExternalLLMCheckReport {
    func withDetailPrefix(_ prefix: String) -> ExternalLLMCheckReport {
        ExternalLLMCheckReport(
            ok: ok,
            status: status,
            detail: "\(prefix) \(detail)",
            modelIDs: modelIDs
        )
    }
}
