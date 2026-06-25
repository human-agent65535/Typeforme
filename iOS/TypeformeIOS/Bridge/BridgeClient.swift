import Foundation

enum BridgeClientError: LocalizedError {
    case invalidURL
    case unauthorizedOrUnavailable
    case invalidResponse
    case server(String)
    case unsupportedAudioFormat(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid bridge URL"
        case .unauthorizedOrUnavailable:
            return "Bridge unavailable or token rejected"
        case .invalidResponse:
            return "Bridge returned an invalid response"
        case .server(let message):
            return message
        case .unsupportedAudioFormat(let detail):
            return "Bridge upload audio must be M4A/AAC; got \(detail)"
        }
    }
}

struct BridgeClient: Sendable {
    private static let clientAppName = "iOS"
    private static let clientAppCategory = AppCategory.chat

    let baseURL: URL
    let token: String

    init?(baseURLString: String, token: String) {
        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        self.baseURL = url
        self.token = token
    }

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    func health(timeout: TimeInterval = 2.5) async -> Bool {
        do {
            let response = try await healthResponse(timeout: timeout)
            return response.ok
        } catch {
            return false
        }
    }

    func healthResponse(timeout: TimeInterval = 2.5) async throws -> BridgeHealthResponse {
        let endpoint = BridgeAPIEndpoint.health
        return try await request(
            path: endpoint.path,
            method: endpoint.method,
            body: Optional<Data>.none,
            timeout: timeout
        )
    }

    func pairing(timeout: TimeInterval = 10) async throws -> PairingConfig {
        let endpoint = BridgeAPIEndpoint.pairing
        let payload: BridgePairingPayload = try await request(
            path: endpoint.path,
            method: endpoint.method,
            body: Optional<Data>.none,
            timeout: timeout
        )
        return payload.config()
    }

    func macSettings(timeout: TimeInterval = 10) async throws -> BridgeMacSettingsPayload {
        let endpoint = BridgeAPIEndpoint.settingsRead
        return try await request(
            path: endpoint.path,
            method: endpoint.method,
            body: Optional<Data>.none,
            timeout: timeout
        )
    }

    func updateMacSettings(
        _ settings: BridgeMacSettingsPayload,
        timeout: TimeInterval = 15
    ) async throws -> BridgeMacSettingsPayload {
        let payload = BridgeSettingsUpdateRequest(editableSnapshot: settings.editableSnapshot)
        let endpoint = BridgeAPIEndpoint.settingsWrite
        return try await request(path: endpoint.path, method: endpoint.method, json: payload, timeout: timeout)
    }

    func dictate(
        audioURL: URL,
        audioExtension: String,
        languageIDs: [String],
        correctionMode: CorrectionMode,
        contextBefore: String = "",
        contextAfter: String = "",
        includeRawTranscript: Bool,
        clientJobID: String? = nil,
        alternateTranscript: String? = nil,
        onJobEvent: (@Sendable (BridgeJobStatusEvent) async -> Void)? = nil
    ) async throws -> BridgeDictateResponse {
        let ext = (audioURL.pathExtension.isEmpty ? audioExtension : audioURL.pathExtension).lowercased()
        guard BridgeAudioFormat.isAllowedExtension(ext) else {
            throw BridgeClientError.unsupportedAudioFormat(ext.isEmpty ? "missing extension" : ext)
        }
        return try await performWithJobEvents(clientJobID: clientJobID, onJobEvent: onJobEvent) { normalizedJobID in
            let multipart = try Self.multipartDictateBody(
                audioURL: audioURL,
                audioExtension: ext,
                languageIDs: languageIDs,
                correctionMode: correctionMode.rawValue,
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                includeRawTranscript: includeRawTranscript,
                clientJobID: normalizedJobID,
                alternateTranscript: alternateTranscript
            )
            let endpoint = BridgeAPIEndpoint.dictate
            return try await request(
                path: endpoint.path,
                method: endpoint.method,
                body: multipart.body,
                contentType: multipart.contentType,
                timeout: 45
            )
        }
    }

    func startLivePreview(
        languageIDs: [String],
        correctionMode: CorrectionMode,
        clientJobID: String? = nil,
        timeout: TimeInterval = 5
    ) async throws -> BridgeLivePreviewStartResponse {
        let payload = BridgeLivePreviewStartRequest(
            clientJobID: clientJobID,
            languageIDs: languageIDs,
            correctionMode: correctionMode.rawValue,
            appName: Self.clientAppName,
            appCategory: Self.clientAppCategory.rawValue
        )
        let endpoint = BridgeAPIEndpoint.livePreviewStart
        return try await request(path: endpoint.path, method: endpoint.method, json: payload, timeout: timeout)
    }

    func livePreviewWebSocketTask(
        sessionID: String,
        timeout: TimeInterval = 10 * 60
    ) throws -> URLSessionWebSocketTask {
        guard let encodedSessionID = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw BridgeClientError.invalidURL
        }
        var request: URLRequest
        do {
            let endpoint = BridgeAPIEndpoint.livePreviewSocket(sessionID: encodedSessionID)
            request = try http.makeRequest(
                path: endpoint.path,
                method: endpoint.method,
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
            throw BridgeClientError.invalidURL
        }
        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        default:
            throw BridgeClientError.invalidURL
        }
        guard let webSocketURL = components.url else {
            throw BridgeClientError.invalidURL
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
            throw BridgeClientError.invalidURL
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
                appName: Self.clientAppName,
                appCategory: Self.clientAppCategory.rawValue
            )
            let endpoint = BridgeAPIEndpoint.refine
            return try await request(path: endpoint.path, method: endpoint.method, json: payload, timeout: 20)
        }
    }

    func editText(
        intent: String,
        contextBefore: String,
        targetText: String,
        contextAfter: String,
        spokenInstruction: String,
        languageIDs: [String],
        clientJobID: String? = nil,
        onJobEvent: (@Sendable (BridgeJobStatusEvent) async -> Void)? = nil
    ) async throws -> BridgeTextEditResponse {
        try await performWithJobEvents(clientJobID: clientJobID, onJobEvent: onJobEvent) { normalizedJobID in
            let payload = BridgeTextEditRequest(
                intent: intent,
                contextBefore: contextBefore,
                targetText: targetText,
                contextAfter: contextAfter,
                spokenInstruction: spokenInstruction,
                languageIDs: languageIDs,
                appName: Self.clientAppName,
                appCategory: Self.clientAppCategory.rawValue,
                clientJobID: normalizedJobID
            )
            let endpoint = BridgeAPIEndpoint.editText
            return try await request(path: endpoint.path, method: endpoint.method, json: payload, timeout: 30)
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
                    // progress channel best-effort by reconnecting; the Mac
                    // side replays recent job events for this client job id.
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
        guard let safeJobID = BridgeClientJobID.normalized(jobID),
              let encodedJobID = safeJobID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else {
            throw BridgeClientError.invalidURL
        }
        let request: URLRequest
        do {
            let endpoint = BridgeAPIEndpoint.jobEvents(jobID: encodedJobID)
            request = try http.makeRequest(
                path: endpoint.path,
                method: endpoint.method,
                timeout: 60,
                accept: "text/event-stream",
                acceptEncoding: nil
            )
        } catch {
            throw mapHTTPError(error)
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeClientError.invalidResponse
        }
        guard http.statusCode != 401 && http.statusCode != 403 && http.statusCode != 404 else {
            throw BridgeClientError.unauthorizedOrUnavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BridgeClientError.server("HTTP \(http.statusCode)")
        }

        var dataLines: [String] = []
        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty {
                guard !dataLines.isEmpty else { continue }
                let dataText = dataLines.joined(separator: "\n")
                dataLines.removeAll(keepingCapacity: true)
                guard let data = dataText.data(using: .utf8),
                      let event = try? JSONDecoder().decode(BridgeJobStatusEvent.self, from: data)
                else {
                    continue
                }
                await onEvent(event)
                if event.stage.isTerminal {
                    return true
                }
                continue
            }
            if line.hasPrefix(":") {
                continue
            }
            if line.hasPrefix("data:") {
                let value = line.dropFirst(5)
                dataLines.append(String(value).trimmingCharacters(in: .whitespaces))
            }
        }
        return false
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

    private var http: BridgeHTTPClientCore {
        BridgeHTTPClientCore(baseURL: baseURL, token: token, applyClientIdentity: BridgeClientIdentity.apply(to:))
    }

    private func mapHTTPError(_ error: Error) -> Error {
        guard let error = error as? BridgeHTTPClientCoreError else { return error }
        switch error {
        case .invalidURL:
            return BridgeClientError.invalidURL
        case .invalidResponse:
            return BridgeClientError.invalidResponse
        case .decodingFailed:
            return BridgeClientError.invalidResponse
        case .unauthorized, .forbidden, .notFound:
            return BridgeClientError.unauthorizedOrUnavailable
        case .server(let message):
            return BridgeClientError.server(message)
        }
    }

    private static func multipartDictateBody(
        audioURL: URL,
        audioExtension: String,
        languageIDs: [String],
        correctionMode: String,
        contextBefore: String,
        contextAfter: String,
        includeRawTranscript: Bool,
        clientJobID: String?,
        alternateTranscript: String? = nil
    ) throws -> (body: Data, contentType: String) {
        let multipart = try BridgeMultipart.dictateBody(
            audioURL: audioURL,
            audioExtension: audioExtension,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            appName: Self.clientAppName,
            appCategory: Self.clientAppCategory.rawValue,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            includeRawTranscript: includeRawTranscript,
            clientJobID: clientJobID,
            alternateTranscript: alternateTranscript
        )
        return (multipart.body, multipart.contentType)
    }

}
