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
    ) async throws -> (client: RemoteBridgeClient, routeStatus: BridgeRouteResolutionStatus) {
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
        let endpoint = BridgeAPIEndpoint.health
        return try await request(path: endpoint.path, method: endpoint.method, body: Optional<Data>.none, timeout: timeout)
    }

    func settings(timeout: TimeInterval = 10) async throws -> BridgeSettingsPayload {
        let endpoint = BridgeAPIEndpoint.settingsRead
        var response: BridgeSettingsPayload = try await request(
            path: endpoint.path,
            method: endpoint.method,
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
        let payload = BridgeSettingsUpdateRequest(editableSnapshot: settings.editableSnapshot)
        let endpoint = BridgeAPIEndpoint.settingsWrite
        var response: BridgeSettingsPayload = try await request(
            path: endpoint.path,
            method: endpoint.method,
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
        let endpoint = BridgeAPIEndpoint.dictate
        let response: BridgeDictateResponse = try await request(
            path: endpoint.path,
            method: endpoint.method,
            bodyFileURL: multipart.fileURL,
            contentLength: multipart.contentLength,
            contentType: multipart.contentType,
            timeout: 90
        )
        try validate(response)
        return response
    }

    func refine(
        sessionID: String?,
        rawTranscript: String?,
        languageIDs: [String],
        correctionMode: CorrectionMode,
        appSnapshot: FrontmostAppSnapshot?,
        appCategory: AppCategory,
        contextBefore: String = "",
        contextAfter: String = ""
    ) async throws -> BridgeRefineResponse {
        let payload = BridgeRefineRequest(
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
        let endpoint = BridgeAPIEndpoint.refine
        let response: BridgeRefineResponse = try await request(
            path: endpoint.path,
            method: endpoint.method,
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
        let payload = BridgeTextEditRequest(
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
        let endpoint = BridgeAPIEndpoint.editText
        let response: BridgeTextEditResponse = try await request(
            path: endpoint.path,
            method: endpoint.method,
            json: payload,
            timeout: 45
        )
        try validate(response)
        return response
    }

    private func validate(_ response: BridgeDictateResponse) throws {
        try Self.validateTextResponse(
            text: response.text,
            status: response.correctionStatus,
            error: response.correctionError
        )
    }

    private func validate(_ response: BridgeRefineResponse) throws {
        try Self.validateTextResponse(
            text: response.text,
            status: response.correctionStatus,
            error: response.correctionError
        )
    }

    private func validate(_ response: BridgeTextEditResponse) throws {
        try Self.validateTextResponse(
            text: response.text,
            status: response.editStatus,
            error: response.editError
        )
    }

    static func validateTextResponse(text: String, status: String?, error: String?) throws {
        if status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "error" {
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
        case .invalidResponse, .decodingFailed(_):
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
