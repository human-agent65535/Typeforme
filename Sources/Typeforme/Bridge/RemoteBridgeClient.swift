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
        guard let expectedRevision = settings.settingsRevision?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedRevision.isEmpty
        else {
            throw RemoteBridgeClientError.invalidResponse
        }
        let payload = BridgeSettingsUpdateRequest(
            editableSnapshot: settings.editableSnapshot,
            expectedSettingsRevision: expectedRevision
        )
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
        alternateTranscript: String? = nil,
        clientJobID: String? = nil,
        onJobEvent: (@Sendable (BridgeJobStatusEvent) async -> Void)? = nil
    ) async throws -> BridgeDictateResponse {
        try await performWithJobEvents(clientJobID: clientJobID, onJobEvent: onJobEvent) { normalizedJobID in
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
                clientJobID: normalizedJobID,
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
    }

    func startLivePreview(
        languageIDs: [String],
        correctionMode: CorrectionMode,
        livePreviewSource: VoiceLivePreviewSource,
        appSnapshot: FrontmostAppSnapshot?,
        appCategory: AppCategory,
        clientJobID: String? = nil,
        timeout: TimeInterval = 5
    ) async throws -> BridgeLivePreviewStartResponse {
        let payload = BridgeLivePreviewStartRequest(
            clientJobID: clientJobID,
            languageIDs: languageIDs,
            correctionMode: correctionMode.rawValue,
            livePreviewSource: livePreviewSource.rawValue,
            appName: appSnapshot?.localizedName,
            bundleID: appSnapshot?.bundleID,
            appCategory: appCategory.rawValue
        )
        let endpoint = BridgeAPIEndpoint.livePreviewStart
        return try await request(path: endpoint.path, method: endpoint.method, json: payload, timeout: timeout)
    }

    func livePreviewWebSocketTask(
        sessionID: String,
        timeout: TimeInterval = 10 * 60
    ) throws -> URLSessionWebSocketTask {
        guard let encodedSessionID = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw RemoteBridgeClientError.invalidURL
        }
        var request: URLRequest
        do {
            let endpoint = BridgeAPIEndpoint.livePreviewSocket(sessionID: encodedSessionID)
            request = try http.makeRequest(
                path: endpoint.path,
                method: "GET",
                timeout: timeout,
                accept: "application/json",
                acceptEncoding: nil
            )
        } catch {
            throw mapHTTPError(error)
        }
        guard let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw RemoteBridgeClientError.invalidURL
        }
        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        default:
            throw RemoteBridgeClientError.invalidURL
        }
        guard let webSocketURL = components.url else {
            throw RemoteBridgeClientError.invalidURL
        }
        request.url = webSocketURL
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 512 * 1024
        return task
    }

    func jobEventsWebSocketTask(
        jobID: String,
        timeout: TimeInterval = 60
    ) throws -> URLSessionWebSocketTask {
        guard let safeJobID = BridgeClientJobID.normalized(jobID),
              let encodedJobID = safeJobID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else {
            throw RemoteBridgeClientError.invalidURL
        }
        var request: URLRequest
        do {
            let endpoint = BridgeAPIEndpoint.jobEvents(jobID: encodedJobID)
            request = try http.makeRequest(
                path: endpoint.path,
                method: "GET",
                timeout: timeout,
                accept: "application/json",
                acceptEncoding: nil
            )
        } catch {
            throw mapHTTPError(error)
        }
        guard let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw RemoteBridgeClientError.invalidURL
        }
        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        default:
            throw RemoteBridgeClientError.invalidURL
        }
        guard let webSocketURL = components.url else {
            throw RemoteBridgeClientError.invalidURL
        }
        request.url = webSocketURL
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 512 * 1024
        return task
    }

    func finishLivePreview(
        sessionID: String,
        timeout: TimeInterval = 5
    ) async throws -> BridgeLivePreviewFinishResponse {
        guard let encodedSessionID = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw RemoteBridgeClientError.invalidURL
        }
        let endpoint = BridgeAPIEndpoint.livePreviewFinish(sessionID: encodedSessionID)
        return try await request(
            path: endpoint.path,
            method: endpoint.method,
            body: Optional<Data>.none,
            timeout: timeout
        )
    }

    func refine(
        sessionID: String?,
        rawTranscript: String?,
        languageIDs: [String],
        correctionMode: CorrectionMode,
        appSnapshot: FrontmostAppSnapshot?,
        appCategory: AppCategory,
        contextBefore: String = "",
        contextAfter: String = "",
        clientJobID: String? = nil,
        onJobEvent: (@Sendable (BridgeJobStatusEvent) async -> Void)? = nil
    ) async throws -> BridgeRefineResponse {
        try await performWithJobEvents(clientJobID: clientJobID, onJobEvent: onJobEvent) { normalizedJobID in
            let payload = BridgeRefineRequest(
                sessionID: sessionID,
                rawTranscript: rawTranscript,
                clientJobID: normalizedJobID,
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
    }

    func editText(
        intent: TextEditIntent,
        contextBefore: String,
        targetText: String,
        contextAfter: String,
        spokenInstruction: String,
        languageIDs: [String],
        appSnapshot: FrontmostAppSnapshot?,
        appCategory: AppCategory,
        clientJobID: String? = nil,
        onJobEvent: (@Sendable (BridgeJobStatusEvent) async -> Void)? = nil
    ) async throws -> BridgeTextEditResponse {
        try await performWithJobEvents(clientJobID: clientJobID, onJobEvent: onJobEvent) { normalizedJobID in
            let payload = BridgeTextEditRequest(
                intent: intent.rawValue,
                contextBefore: contextBefore,
                targetText: targetText,
                contextAfter: contextAfter,
                spokenInstruction: spokenInstruction,
                languageIDs: languageIDs,
                appName: appSnapshot?.localizedName,
                bundleID: appSnapshot?.bundleID,
                appCategory: appCategory.rawValue,
                clientJobID: normalizedJobID
            )
            let endpoint = BridgeAPIEndpoint.editText
            let response: BridgeTextEditResponse = try await request(
                path: endpoint.path,
                method: endpoint.method,
                json: payload,
                timeout: 45
            )
            let validationRequest = TextEditRequest(
                intent: intent,
                contextBefore: contextBefore,
                targetText: targetText,
                contextAfter: contextAfter,
                spokenInstruction: spokenInstruction,
                languageIDs: languageIDs,
                frontmostAppName: appSnapshot?.localizedName,
                frontmostBundleID: appSnapshot?.bundleID,
                appCategory: appCategory,
                numberOutputPreference: AppSettings.numberOutputPreference,
                punctuationPreference: AppSettings.punctuationPreference,
                userDictionary: []
            )
            try validate(response, request: validationRequest)
            return response
        }
    }

    private func performWithJobEvents<Response>(
        clientJobID: String?,
        onJobEvent: (@Sendable (BridgeJobStatusEvent) async -> Void)?,
        operation: (String?) async throws -> Response
    ) async throws -> Response {
        let normalizedJobID = BridgeClientJobID.normalized(clientJobID)
        let eventTask: Task<Void, Never>? = {
            guard let normalizedJobID, let onJobEvent else { return nil }
            return jobEventTask(jobID: normalizedJobID, onEvent: onJobEvent)
        }()
        defer {
            eventTask?.cancel()
        }
        return try await operation(normalizedJobID)
    }

    private func jobEventTask(
        jobID: String,
        onEvent: @escaping @Sendable (BridgeJobStatusEvent) async -> Void
    ) -> Task<Void, Never> {
        Task {
            var attempt = 0
            while !Task.isCancelled {
                do {
                    if try await streamJobEvents(jobID: jobID, onEvent: onEvent) {
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // The paired POST still returns the final result. Keep the
                    // progress channel best-effort by reconnecting; the Bridge
                    // replays recent job events for this client job id.
                }
                attempt += 1
                let delayMs = min(1_000, 150 * attempt)
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }
        }
    }

    @discardableResult
    func streamJobEvents(
        jobID: String,
        onEvent: @Sendable (BridgeJobStatusEvent) async -> Void
    ) async throws -> Bool {
        let task = try jobEventsWebSocketTask(jobID: jobID)
        return try await withTaskCancellationHandler(operation: {
            task.resume()
            defer { task.cancel(with: .normalClosure, reason: nil) }
            while !Task.isCancelled {
                let event = try Self.decodeJobStatusEvent(try await task.receive())
                await onEvent(event)
                if event.stage.isTerminal {
                    return true
                }
            }
            return false
        }, onCancel: {
            task.cancel(with: .normalClosure, reason: nil)
        })
    }

    private static func decodeJobStatusEvent(_ message: URLSessionWebSocketTask.Message) throws -> BridgeJobStatusEvent {
        let data: Data
        switch message {
        case .data(let payload):
            data = payload
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            throw RemoteBridgeClientError.invalidResponse
        }
        return try JSONDecoder().decode(BridgeJobStatusEvent.self, from: data)
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

    private func validate(_ response: BridgeTextEditResponse, request: TextEditRequest) throws {
        try validate(response)
        let action: TextEditAction
        if let rawAction = response.action {
            guard let parsed = TextEditAction(rawValue: rawAction) else {
                throw RemoteBridgeClientError.correctionFailed("Remote edit returned an invalid action")
            }
            action = parsed
        } else {
            action = .replaceTarget
        }
        try TextEditValidator.validate(TextEditResult(action: action, text: response.text), for: request)
    }

    static func validateTextResponse(text: String, status: String?, error: String?) throws {
        let normalizedStatus = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedStatus == "error" {
            throw RemoteBridgeClientError.correctionFailed(error ?? "")
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if normalizedStatus == "empty" { return }
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
        case .invalidResponse, .decodingFailed(_), .responseTooLarge:
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
