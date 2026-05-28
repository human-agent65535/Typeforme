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

private struct BridgeErrorResponse: Decodable {
    let error: String
}

struct BridgeClient {
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
        try await request(
            path: "/v1/health",
            method: "GET",
            body: Optional<Data>.none,
            timeout: timeout
        )
    }

    func pairing(timeout: TimeInterval = 10) async throws -> PairingConfig {
        let payload: PairingPayload = try await request(
            path: "/v1/pairing",
            method: "GET",
            body: Optional<Data>.none,
            timeout: timeout
        )
        return payload.config()
    }

    func macSettings(timeout: TimeInterval = 10) async throws -> BridgeMacSettingsPayload {
        try await request(
            path: "/v1/settings",
            method: "GET",
            body: Optional<Data>.none,
            timeout: timeout
        )
    }

    func updateMacSettings(
        _ settings: BridgeMacSettingsPayload,
        timeout: TimeInterval = 15
    ) async throws -> BridgeMacSettingsPayload {
        let payload = BridgeSettingsUpdateRequest(
            asrProvider: settings.asrProvider,
            languageIDs: settings.languageIDs,
            asrTimeoutSec: settings.asrTimeoutSec,
            correctionBackend: settings.correctionBackend,
            correctionTimeoutMs: settings.correctionTimeoutMs,
            correctionColdTimeoutMs: settings.correctionColdTimeoutMs,
            correctionMode: settings.correctionMode.rawValue,
            numberOutputPreference: settings.numberOutputPreference.rawValue,
            punctuationPreference: settings.punctuationPreference.rawValue,
            autoCommit: settings.autoCommit,
            userDictionary: settings.userDictionary
        )
        return try await request(path: "/v1/settings", method: "POST", json: payload, timeout: timeout)
    }

    func dictate(
        audioURL: URL,
        audioExtension: String,
        languageIDs: [String],
        correctionMode: CorrectionModeID,
        contextBefore: String = "",
        contextAfter: String = "",
        includeRawTranscript: Bool,
        clientJobID: String? = nil,
        alternateTranscript: String? = nil,
        onJobEvent: (@Sendable (BridgeJobStatusEvent) async -> Void)? = nil
    ) async throws -> BridgeDictateResponse {
        let ext = (audioURL.pathExtension.isEmpty ? audioExtension : audioURL.pathExtension).lowercased()
        guard ["m4a", "aac"].contains(ext) else {
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
            return try await request(
                path: "/v1/dictate",
                method: "POST",
                body: multipart.body,
                contentType: multipart.contentType,
                timeout: 45
            )
        }
    }

    func restyle(
        sessionID: String?,
        rawTranscript: String?,
        languageIDs: [String],
        correctionMode: CorrectionModeID,
        clientJobID: String? = nil,
        onJobEvent: (@Sendable (BridgeJobStatusEvent) async -> Void)? = nil
    ) async throws -> BridgeRestyleResponse {
        try await performWithJobEvents(clientJobID: clientJobID, onJobEvent: onJobEvent) { normalizedJobID in
            let payload = BridgeRestyleRequest(
                sessionID: sessionID,
                rawTranscript: rawTranscript,
                clientJobID: normalizedJobID,
                languageIDs: languageIDs,
                correctionMode: correctionMode.rawValue,
                appName: "iOS",
                appCategory: "chat"
            )
            return try await request(path: "/v1/restyle", method: "POST", json: payload, timeout: 20)
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
                clientJobID: normalizedJobID,
                appName: "iOS",
                appCategory: "chat"
            )
            return try await request(path: "/v1/edit-text", method: "POST", json: payload, timeout: 30)
        }
    }

    private func performWithJobEvents<Response>(
        clientJobID: String?,
        onJobEvent: (@Sendable (BridgeJobStatusEvent) async -> Void)?,
        operation: (String?) async throws -> Response
    ) async throws -> Response {
        let normalizedJobID = Self.normalizedClientJobID(clientJobID)
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
        guard let safeJobID = Self.normalizedClientJobID(jobID),
              let encodedJobID = safeJobID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else {
            throw BridgeClientError.invalidURL
        }
        let request = try makeRequest(
            path: "/v1/jobs/\(encodedJobID)/events",
            method: "GET",
            timeout: 60,
            accept: "text/event-stream",
            acceptEncoding: nil
        )

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
        let data = try JSONEncoder().encode(body)
        return try await request(path: path, method: method, body: data, contentType: "application/json", timeout: timeout)
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        body: Data?,
        contentType: String? = nil,
        timeout: TimeInterval
    ) async throws -> T {
        var request = try makeRequest(
            path: path,
            method: method,
            timeout: timeout,
            accept: "application/json",
            acceptEncoding: "gzip"
        )
        if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeClientError.invalidResponse
        }
        guard http.statusCode != 401 && http.statusCode != 403 && http.statusCode != 404 else {
            throw BridgeClientError.unauthorizedOrUnavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(BridgeErrorResponse.self, from: data).error)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw BridgeClientError.server(message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func makeRequest(
        path: String,
        method: String,
        timeout: TimeInterval,
        accept: String,
        acceptEncoding: String?
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw BridgeClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let acceptEncoding {
            request.setValue(acceptEncoding, forHTTPHeaderField: "Accept-Encoding")
        }
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        BridgeClientIdentity.apply(to: &request)
        return request
    }

    private static func multipartDictateBody(
        audioURL: URL,
        audioExtension: String,
        languageIDs: [String],
        correctionMode: String,
        contextBefore: String,
        contextAfter: String,
        includeRawTranscript: Bool
    ) throws -> (body: Data, contentType: String) {
        try multipartDictateBody(
            audioURL: audioURL,
            audioExtension: audioExtension,
            languageIDs: languageIDs,
            correctionMode: correctionMode,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            includeRawTranscript: includeRawTranscript,
            clientJobID: nil,
            alternateTranscript: nil
        )
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
            appName: "iOS",
            appCategory: "chat",
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            includeRawTranscript: includeRawTranscript,
            clientJobID: clientJobID,
            alternateTranscript: alternateTranscript
        )
        return (multipart.body, multipart.contentType)
    }

    private static func normalizedClientJobID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 96 else { return nil }
        let allowed = trimmed.filter { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
        return allowed == trimmed ? trimmed : nil
    }

}
