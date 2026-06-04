import Foundation

struct LMStudioCheckReport: Sendable {
    let ok: Bool
    let status: String
    let detail: String
    let modelIDs: [String]
}

typealias LMStudioModelIDFetcher = @Sendable (_ endpoint: URL, _ apiKey: String?, _ timeout: TimeInterval) async throws -> [String]

final class LMStudioCorrectorService: CorrectorService {
    let kind: CorrectionBackendKind = .externalLMStudio

    static let minimumRequestTimeoutMs = 100
    private static let configurationCheckTimeout: TimeInterval = 5
    private static let invalidAPIKeyProbePrefix = "typeforme-invalid-lmstudio-token-"

    func correct(_ request: CorrectionRequest, timeoutMs: Int) async throws -> CorrectionResult {
        let (system, user) = PromptBuilder.build(for: request)
        let content = try await complete(system: system, user: user, timeoutMs: timeoutMs)
        do {
            var result = try CorrectionValidator.parseAndValidate(rawOutput: content, for: request)
            result.text = ProtectedSpanPostProcessor.apply(result.text, rawTranscript: request.rawTranscript)
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
        let model = AppSettings.lmStudioModel
        guard !model.isEmpty else {
            throw CorrectorError.unavailable("Set the LM Studio model identifier in Settings")
        }

        let endpoint = try Self.chatCompletionsEndpoint(baseURL: AppSettings.lmStudioBaseURL)

        let body = CorrectorChatRequestBuilder.body(
            model: model,
            system: system,
            user: user,
            maxTokens: AppSettings.correctionMaxTokens
        )
        let requestTimeoutMs = Self.effectiveTimeoutMs(timeoutMs)
        do {
            return try await OpenAICompatibleClient.chatCompletionContent(
                endpoint: endpoint,
                request: body,
                apiKey: AppSettings.lmStudioAPIKey,
                timeoutMs: requestTimeoutMs
            )
        } catch let error as OpenAICompatibleClientError {
            throw error.correctorError
        }
    }

    static func effectiveTimeoutMs(_ configuredTimeoutMs: Int) -> Int {
        max(configuredTimeoutMs, minimumRequestTimeoutMs)
    }

    static func checkConfiguration(
        baseURL: String = AppSettings.lmStudioBaseURL,
        apiKey: String = AppSettings.lmStudioAPIKey,
        selectedModel: String = AppSettings.lmStudioModel,
        modelIDFetcher: LMStudioModelIDFetcher? = nil
    ) async -> LMStudioCheckReport {
        let trimmedAPIKey = normalizedAPIKey(apiKey)
        let fetchModelIDs = modelIDFetcher ?? defaultModelIDFetcher
        do {
            let endpoint = try modelsEndpoint(baseURL: baseURL)
            let modelIDs = try await fetchModelIDs(endpoint, trimmedAPIKey, configurationCheckTimeout)
            if trimmedAPIKey != nil,
               let verificationFailure = await apiKeyVerificationFailureReport(
                endpoint: endpoint,
                modelIDs: modelIDs,
                modelIDFetcher: fetchModelIDs
               ) {
                return verificationFailure
            }
            let report = availabilityReport(modelIDs: modelIDs, selectedModel: selectedModel)
            return trimmedAPIKey == nil ? report : report.withDetailPrefix("API key verified.")
        } catch let error as OpenAICompatibleClientError where error.isAuthenticationFailure {
            let detail = trimmedAPIKey == nil
                ? "LM Studio requires an API key. Enter a valid API token from LM Studio Server Settings."
                : "LM Studio rejected the API key. Check the token and its permissions in LM Studio Server Settings."
            return LMStudioCheckReport(ok: false, status: "Failed", detail: detail, modelIDs: [])
        } catch {
            return LMStudioCheckReport(ok: false, status: "Failed", detail: error.localizedDescription, modelIDs: [])
        }
    }

    static func chatCompletionsEndpoint(baseURL: String) throws -> URL {
        try openAICompatibleEndpoint(baseURL: baseURL, path: "/chat/completions")
    }

    static func modelsEndpoint(baseURL: String) throws -> URL {
        try openAICompatibleEndpoint(baseURL: baseURL, path: "/models")
    }

    private static func openAICompatibleEndpoint(baseURL: String, path: String) throws -> URL {
        let normalized = try openAICompatibleBaseURLString(baseURL)
        guard let url = URL(string: normalized + path) else {
            throw CorrectorError.unavailable("Invalid LM Studio URL")
        }
        try validateHTTPURL(url)
        return url
    }

    private static func openAICompatibleBaseURLString(_ baseURL: String) throws -> String {
        let normalized = normalizedBaseURLString(baseURL)
        guard !normalized.isEmpty else {
            throw CorrectorError.unavailable("LM Studio URL is empty")
        }
        guard var components = URLComponents(string: normalized) else {
            throw CorrectorError.unavailable("Invalid LM Studio URL")
        }
        components.query = nil
        components.fragment = nil
        var path = components.percentEncodedPath
        if path.hasSuffix("/chat/completions") {
            path = String(path.dropLast("/chat/completions".count))
        }
        if path.hasSuffix("/models") {
            path = String(path.dropLast("/models".count))
        }
        if path.isEmpty {
            path = "/v1"
        } else if !path.hasSuffix("/v1") {
            path += "/v1"
        }
        components.percentEncodedPath = path
        guard let url = components.url else { throw CorrectorError.unavailable("Invalid LM Studio URL") }
        try validateHTTPURL(url)
        return url.absoluteString
    }

    private static func validateHTTPURL(_ url: URL) throws {
        guard
            let scheme = url.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            url.host != nil
        else {
            throw CorrectorError.unavailable("LM Studio URL must be an http or https URL")
        }
    }

    static func modelIDs(data: Data) -> [String] {
        OpenAICompatibleClient.modelIDs(data: data)
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

    static func availabilityReport(modelIDs: [String], selectedModel: String) -> LMStudioCheckReport {
        let selected = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelIDs.isEmpty else {
            let hint = selected.isEmpty
                ? "Load a model in LM Studio before using correction."
                : "Load \(selected) in LM Studio before using correction."
            return LMStudioCheckReport(
                ok: false,
                status: "Failed",
                detail: "LM Studio is reachable, but no models are loaded. \(hint)",
                modelIDs: []
            )
        }
        guard selected.isEmpty || modelIDs.contains(selected) else {
            let fallback = modelIDs[0]
            return LMStudioCheckReport(
                ok: true,
                status: "Ready",
                detail: "Selected model \(selected) is not loaded. Using \(fallback). \(modelListSummary(modelIDs: modelIDs))",
                modelIDs: modelIDs
            )
        }
        return LMStudioCheckReport(
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

    private static let defaultModelIDFetcher: LMStudioModelIDFetcher = { endpoint, apiKey, timeout in
        try await OpenAICompatibleClient.modelIDs(endpoint: endpoint, apiKey: apiKey, timeout: timeout)
    }

    private static func apiKeyVerificationFailureReport(
        endpoint: URL,
        modelIDs: [String],
        modelIDFetcher: LMStudioModelIDFetcher
    ) async -> LMStudioCheckReport? {
        do {
            _ = try await modelIDFetcher(endpoint, invalidAPIKeyProbe(), configurationCheckTimeout)
            return LMStudioCheckReport(
                ok: false,
                status: "Failed",
                detail: "LM Studio accepted a deliberately invalid API key. Enable Require Authentication in LM Studio Server Settings, then refresh models to verify the configured key.",
                modelIDs: modelIDs
            )
        } catch let error as OpenAICompatibleClientError where error.isAuthenticationFailure {
            return nil
        } catch {
            return LMStudioCheckReport(
                ok: false,
                status: "Failed",
                detail: "Could not verify that LM Studio rejects invalid API keys: \(error.localizedDescription)",
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

private extension LMStudioCheckReport {
    func withDetailPrefix(_ prefix: String) -> LMStudioCheckReport {
        LMStudioCheckReport(
            ok: ok,
            status: status,
            detail: "\(prefix) \(detail)",
            modelIDs: modelIDs
        )
    }
}
