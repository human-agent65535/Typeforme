import Foundation

enum RemoteBridgeClientError: LocalizedError {
    case missingURL
    case missingToken
    case invalidURL
    case unavailable
    case unauthorized
    case forbidden
    case notFound
    case invalidResponse
    case server(String)
    case correctionFailed(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .missingURL:
            return "Client Bridge URL is empty"
        case .missingToken:
            return "Client Bridge token is empty"
        case .invalidURL:
            return "Client Bridge URL is invalid"
        case .unavailable:
            return "Client Bridge is unavailable"
        case .unauthorized:
            return "Client Bridge token is missing or rejected"
        case .forbidden:
            return "Client Bridge access is forbidden for this token"
        case .notFound:
            return "Client Bridge endpoint was not found; check the URL"
        case .invalidResponse:
            return "Client Bridge returned an invalid response"
        case .server(let message):
            return message
        case .correctionFailed(let message):
            return message.isEmpty ? "Remote correction failed" : message
        case .emptyResult:
            return "Remote Bridge returned an empty result"
        }
    }
}

private struct RemoteBridgeRestyleRequest: Encodable {
    let sessionID: String?
    let rawTranscript: String?
    let languageIDs: [String]
    let correctionMode: String
    let appName: String?
    let bundleID: String?
    let appCategory: String
    let contextBefore: String?
    let contextAfter: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case rawTranscript = "raw_transcript"
        case languageIDs = "language_ids"
        case correctionMode = "correction_mode"
        case appName = "app_name"
        case bundleID = "bundle_id"
        case appCategory = "app_category"
        case contextBefore = "context_before"
        case contextAfter = "context_after"
    }
}

private struct RemoteBridgeTextEditRequest: Encodable {
    let intent: String
    let contextBefore: String
    let targetText: String
    let contextAfter: String
    let spokenInstruction: String
    let languageIDs: [String]
    let appName: String?
    let bundleID: String?
    let appCategory: String

    enum CodingKeys: String, CodingKey {
        case intent
        case contextBefore = "context_before"
        case targetText = "target_text"
        case contextAfter = "context_after"
        case spokenInstruction = "spoken_instruction"
        case languageIDs = "language_ids"
        case appName = "app_name"
        case bundleID = "bundle_id"
        case appCategory = "app_category"
    }
}

private struct RemoteBridgeSettingsUpdateRequest: Encodable {
    let enabledRecognitionSources: [String]
    let asrModelIDsByRecognitionSource: [String: String]
    let languageIDs: [String]
    let asrTimeoutSecByRecognitionSource: [String: Double]
    let correctionBackend: String
    let correctionTimeoutMs: Int
    let correctionColdTimeoutMs: Int
    let externalLLMBaseURL: String?
    let externalLLMModel: String?
    let livePreviewSource: String
    let correctionMode: String
    let numberOutputPreference: String
    let punctuationPreference: String
    let autoCommit: Bool
    let debugMode: Bool
    let userDictionary: [DictionaryEntry]

    enum CodingKeys: String, CodingKey {
        case enabledRecognitionSources = "enabled_recognition_sources"
        case asrModelIDsByRecognitionSource = "asr_model_ids_by_recognition_source"
        case languageIDs = "language_ids"
        case asrTimeoutSecByRecognitionSource = "asr_timeout_sec_by_recognition_source"
        case correctionBackend = "correction_backend"
        case correctionTimeoutMs = "correction_timeout_ms"
        case correctionColdTimeoutMs = "correction_cold_timeout_ms"
        case externalLLMBaseURL = "external_llm_base_url"
        case externalLLMModel = "external_llm_model"
        case livePreviewSource = "live_preview_source"
        case correctionMode = "correction_mode"
        case numberOutputPreference = "number_output_preference"
        case punctuationPreference = "punctuation_preference"
        case autoCommit = "auto_commit"
        case debugMode = "debug_mode"
        case userDictionary = "user_dictionary"
    }
}

struct RemoteBridgeClient {
    let baseURL: URL
    let token: String

    init(baseURLString: String, token: String) throws {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { throw RemoteBridgeClientError.missingURL }
        guard !trimmedToken.isEmpty else { throw RemoteBridgeClientError.missingToken }

        let normalized = ClientBridgeConfiguration.normalizedBaseURL(trimmedURL)
        guard let url = URL(string: normalized), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            throw RemoteBridgeClientError.invalidURL
        }
        self.baseURL = url
        self.token = trimmedToken
    }

    static func resolvedFromSettings(
        probeAllEndpoints: Bool = false
    ) async throws -> (client: RemoteBridgeClient, routeStatus: ClientBridgeRouteStatus) {
        let config = ClientBridgeConfiguration.current
        guard config.hasAnyBridgeURL else { throw RemoteBridgeClientError.missingURL }
        guard !config.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteBridgeClientError.missingToken
        }

        let status = await ClientBridgeRouteResolver().resolve(
            config: config,
            probeAllEndpoints: probeAllEndpoints
        )
        guard let activeURL = status.activeURL else {
            throw RemoteBridgeClientError.unavailable
        }
        return (
            try RemoteBridgeClient(baseURLString: activeURL.absoluteString, token: config.token),
            status
        )
    }

    func health(timeout: TimeInterval = 4) async throws -> BridgeHealthResponse {
        try await request(path: "/v1/health", method: "GET", body: Optional<Data>.none, timeout: timeout)
    }

    func settings(timeout: TimeInterval = 10) async throws -> BridgeSettingsPayload {
        var response: BridgeSettingsPayload = try await request(
            path: "/v1/settings",
            method: "GET",
            body: Optional<Data>.none,
            timeout: timeout
        )
        response.normalize()
        return response
    }

    func updateSettings(
        _ settings: BridgeSettingsPayload,
        timeout: TimeInterval = 15
    ) async throws -> BridgeSettingsPayload {
        let payload = RemoteBridgeSettingsUpdateRequest(
            enabledRecognitionSources: settings.enabledRecognitionSources,
            asrModelIDsByRecognitionSource: settings.asrModelIDsByRecognitionSource,
            languageIDs: settings.languageIDs,
            asrTimeoutSecByRecognitionSource: settings.asrTimeoutSecByRecognitionSource,
            correctionBackend: settings.correctionBackend,
            correctionTimeoutMs: settings.correctionTimeoutMs,
            correctionColdTimeoutMs: settings.correctionColdTimeoutMs,
            externalLLMBaseURL: settings.externalLLMBaseURL,
            externalLLMModel: settings.externalLLMModel,
            livePreviewSource: settings.livePreviewSource,
            correctionMode: settings.correctionMode,
            numberOutputPreference: settings.numberOutputPreference,
            punctuationPreference: settings.punctuationPreference,
            autoCommit: settings.autoCommit,
            debugMode: settings.debugMode,
            userDictionary: settings.userDictionary
        )
        var response: BridgeSettingsPayload = try await request(
            path: "/v1/settings",
            method: "POST",
            json: payload,
            timeout: timeout
        )
        response.normalize()
        return response
    }

    func dictate(
        audioURL: URL,
        languageIDs: [String],
        correctionMode: CorrectionMode,
        appSnapshot: FrontmostAppSnapshot?,
        appCategory: AppCategory,
        contextBefore: String = "",
        contextAfter: String = "",
        includeRawTranscript: Bool = true,
        alternateTranscript: String? = nil
    ) async throws -> BridgeDictateResponse {
        let uploadURL = try ASRAudioSupport.bridgeUploadAudioURL(for: audioURL)
        let multipart = try Self.multipartDictateBodyFile(
            audioURL: uploadURL,
            languageIDs: languageIDs,
            correctionMode: correctionMode.rawValue,
            appName: appSnapshot?.localizedName,
            bundleID: appSnapshot?.bundleID,
            appCategory: appCategory.rawValue,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            includeRawTranscript: includeRawTranscript,
            alternateTranscript: alternateTranscript
        )
        defer { try? FileManager.default.removeItem(at: multipart.fileURL) }
        let response: BridgeDictateResponse = try await request(
            path: "/v1/dictate",
            method: "POST",
            bodyFileURL: multipart.fileURL,
            contentLength: multipart.contentLength,
            contentType: multipart.contentType,
            timeout: 90
        )
        try validate(response)
        return response
    }

    func restyle(
        sessionID: String?,
        rawTranscript: String?,
        languageIDs: [String],
        correctionMode: CorrectionMode,
        appSnapshot: FrontmostAppSnapshot?,
        appCategory: AppCategory,
        contextBefore: String = "",
        contextAfter: String = ""
    ) async throws -> BridgeRestyleResponse {
        let payload = RemoteBridgeRestyleRequest(
            sessionID: sessionID,
            rawTranscript: rawTranscript,
            languageIDs: languageIDs,
            correctionMode: correctionMode.rawValue,
            appName: appSnapshot?.localizedName,
            bundleID: appSnapshot?.bundleID,
            appCategory: appCategory.rawValue,
            contextBefore: contextBefore,
            contextAfter: contextAfter
        )
        let response: BridgeRestyleResponse = try await request(
            path: "/v1/restyle",
            method: "POST",
            json: payload,
            timeout: 45
        )
        try validate(response)
        return response
    }

    func editText(
        intent: TextEditIntent,
        contextBefore: String,
        targetText: String,
        contextAfter: String,
        spokenInstruction: String,
        languageIDs: [String],
        appSnapshot: FrontmostAppSnapshot?,
        appCategory: AppCategory
    ) async throws -> BridgeTextEditResponse {
        let payload = RemoteBridgeTextEditRequest(
            intent: intent.rawValue,
            contextBefore: contextBefore,
            targetText: targetText,
            contextAfter: contextAfter,
            spokenInstruction: spokenInstruction,
            languageIDs: languageIDs,
            appName: appSnapshot?.localizedName,
            bundleID: appSnapshot?.bundleID,
            appCategory: appCategory.rawValue
        )
        let response: BridgeTextEditResponse = try await request(
            path: "/v1/edit-text",
            method: "POST",
            json: payload,
            timeout: 45
        )
        try validate(response)
        return response
    }

    private func validate(_ response: BridgeDictateResponse) throws {
        try validateTextResponse(
            text: response.text,
            status: response.correctionStatus,
            error: response.correctionError
        )
    }

    private func validate(_ response: BridgeRestyleResponse) throws {
        try validateTextResponse(
            text: response.text,
            status: response.correctionStatus,
            error: response.correctionError
        )
    }

    private func validate(_ response: BridgeTextEditResponse) throws {
        try validateTextResponse(
            text: response.text,
            status: response.editStatus,
            error: response.editError
        )
    }

    private func validateTextResponse(text: String, status: String, error: String?) throws {
        if status == "error" {
            throw RemoteBridgeClientError.correctionFailed(error ?? "")
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RemoteBridgeClientError.emptyResult
        }
    }

    private func request<T: Decodable, Body: Encodable>(
        path: String,
        method: String,
        json body: Body,
        timeout: TimeInterval
    ) async throws -> T {
        do {
            return try await http.request(path: path, method: method, json: body, timeout: timeout)
        } catch {
            throw mapHTTPError(error)
        }
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        body: Data?,
        contentType: String? = nil,
        timeout: TimeInterval
    ) async throws -> T {
        do {
            return try await http.request(
                path: path,
                method: method,
                body: body,
                contentType: contentType,
                timeout: timeout
            )
        } catch {
            throw mapHTTPError(error)
        }
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        bodyFileURL: URL,
        contentLength: Int64,
        contentType: String,
        timeout: TimeInterval
    ) async throws -> T {
        do {
            return try await http.request(
                path: path,
                method: method,
                bodyFileURL: bodyFileURL,
                contentLength: contentLength,
                contentType: contentType,
                timeout: timeout
            )
        } catch {
            throw mapHTTPError(error)
        }
    }

    private var http: BridgeHTTPClientCore {
        BridgeHTTPClientCore(baseURL: baseURL, token: token, applyClientIdentity: BridgeClientIdentity.apply(to:))
    }

    private func mapHTTPError(_ error: Error) -> Error {
        guard let error = error as? BridgeHTTPClientCoreError else { return error }
        switch error {
        case .invalidURL:
            return RemoteBridgeClientError.invalidURL
        case .invalidResponse, .decodingFailed:
            return RemoteBridgeClientError.invalidResponse
        case .unauthorized:
            return RemoteBridgeClientError.unauthorized
        case .forbidden:
            return RemoteBridgeClientError.forbidden
        case .notFound:
            return RemoteBridgeClientError.notFound
        case .server(let message):
            return RemoteBridgeClientError.server(message)
        }
    }

    static func multipartDictateBody(
        audioURL: URL,
        languageIDs: [String],
        correctionMode: String,
        appName: String?,
        bundleID: String?,
        appCategory: String,
        contextBefore: String = "",
        contextAfter: String = "",
        includeRawTranscript: Bool,
        clientJobID: String? = nil
    ) throws -> (body: Data, contentType: String) {
        let multipart = try BridgeMultipart.dictateBody(
            audioURL: audioURL,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: appName,
            bundleID: bundleID,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            includeRawTranscript: includeRawTranscript,
            clientJobID: clientJobID
        )
        return (multipart.body, multipart.contentType)
    }

    static func multipartDictateBodyFile(
        audioURL: URL,
        languageIDs: [String],
        correctionMode: String,
        appName: String?,
        bundleID: String?,
        appCategory: String,
        contextBefore: String = "",
        contextAfter: String = "",
        includeRawTranscript: Bool,
        clientJobID: String? = nil,
        alternateTranscript: String? = nil
    ) throws -> (fileURL: URL, contentType: String, contentLength: Int64) {
        let multipart = try BridgeMultipart.dictateBodyFile(
            audioURL: audioURL,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: appName,
            bundleID: bundleID,
            appCategory: appCategory,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            includeRawTranscript: includeRawTranscript,
            clientJobID: clientJobID,
            alternateTranscript: alternateTranscript
        )
        return (multipart.fileURL, multipart.contentType, multipart.contentLength)
    }
}
