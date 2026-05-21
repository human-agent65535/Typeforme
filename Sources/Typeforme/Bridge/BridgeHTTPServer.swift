import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

private struct BridgeRequestContext: RequestContext, RemoteAddressRequestContext {
    var coreContext: CoreRequestContextStorage
    let remoteAddress: SocketAddress?

    init(source: ApplicationRequestContextSource) {
        coreContext = CoreRequestContextStorage(source: source)
        remoteAddress = source.channel.remoteAddress
    }
}

private struct BridgeRequestMetadata: Sendable {
    var appName: String?
    var bundleID: String?

    static let empty = BridgeRequestMetadata()
}

private extension HTTPField.Name {
    static let typeformeClientID = Self(BridgeClientIdentityHeaders.id)!
    static let typeformeClientName = Self(BridgeClientIdentityHeaders.name)!
    static let typeformeClientPlatform = Self(BridgeClientIdentityHeaders.platform)!
    static let typeformeClientBundleID = Self(BridgeClientIdentityHeaders.bundleID)!
    static let cfConnectingIP = Self("CF-Connecting-IP")!
    static let cfRay = Self("CF-Ray")!
    static let xForwardedFor = Self("X-Forwarded-For")!
}

final class BridgeHTTPServer: @unchecked Sendable {
    private let service: BridgeService
    private let stateLock = NSLock()
    private var serverTask: Task<Void, Never>?
    private var pendingStartTask: Task<Void, Never>?
    private var activePort: Int?
    private var activeHost: String?
    private var activeRunID: UUID?
    private var running = false

    private static let maxBodyBytes = 25 * 1024 * 1024
    private static let maxMultipartHeaderBytes = 16 * 1024
    private static let maxMultipartFieldBytes = 1 * 1024 * 1024
    private static let restartSettleDelay: UInt64 = 150_000_000

    @MainActor
    init(dictionary: UserDictionaryStore) {
        service = BridgeService(dictionary: dictionary)
    }

    func applySettings() {
        cancelPendingStart()
        guard AppSettings.bridgeEnabled else {
            stop()
            return
        }

        let port = AppSettings.bridgePort
        let host = Self.bindHost()
        let current = stateSnapshot()
        if current.running, current.port == port, current.host == host { return }
        stop()
        if current.running {
            scheduleStart(host: host, port: port, after: Self.restartSettleDelay)
        } else {
            startIfSettingsStillMatch(host: host, port: port)
        }
    }

    func stop() {
        let task: Task<Void, Never>?
        let pending: Task<Void, Never>?
        stateLock.lock()
        task = serverTask
        pending = pendingStartTask
        serverTask = nil
        pendingStartTask = nil
        activePort = nil
        activeHost = nil
        activeRunID = nil
        running = false
        stateLock.unlock()

        pending?.cancel()
        task?.cancel()
        if task != nil {
            Log.app.info("Bridge stopping")
        }
    }

    static func constantTimeEquals(_ supplied: String, _ expected: String) -> Bool {
        let suppliedBytes = Array(supplied.utf8)
        let expectedBytes = Array(expected.utf8)
        var diff = suppliedBytes.count ^ expectedBytes.count
        let count = max(suppliedBytes.count, expectedBytes.count)
        for i in 0..<count {
            let suppliedByte = i < suppliedBytes.count ? suppliedBytes[i] : 0
            let expectedByte = i < expectedBytes.count ? expectedBytes[i] : 0
            diff |= Int(suppliedByte ^ expectedByte)
        }
        return diff == 0
    }

    private func stateSnapshot() -> (running: Bool, port: Int?, host: String?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (running, activePort, activeHost)
    }

    private func cancelPendingStart() {
        let pending: Task<Void, Never>?
        stateLock.lock()
        pending = pendingStartTask
        pendingStartTask = nil
        stateLock.unlock()
        pending?.cancel()
    }

    private static func bindHost() -> String {
        AppSettings.bridgeLANEnabled ? "0.0.0.0" : "127.0.0.1"
    }

    private func scheduleStart(host: String, port: Int, after delay: UInt64) {
        let task = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.startIfSettingsStillMatch(host: host, port: port)
        }
        stateLock.lock()
        pendingStartTask = task
        stateLock.unlock()
    }

    private func startIfSettingsStillMatch(host: String, port: Int) {
        guard AppSettings.bridgeEnabled,
              AppSettings.bridgePort == port,
              Self.bindHost() == host
        else { return }
        let current = stateSnapshot()
        guard !current.running else { return }
        start(host: host, port: port)
    }

    private func start(host: String, port: Int) {
        let runID = UUID()
        let app = makeApplication(host: host, port: port)
        let task = Task.detached(priority: .utility) { [weak self] in
            defer {
                self?.markStopped(runID: runID)
            }
            do {
                try await app.runService(gracefulShutdownSignals: [])
            } catch is CancellationError {
                Log.app.info("Bridge stopped")
            } catch {
                Log.app.error("Bridge server failed: \(error.localizedDescription)")
            }
        }

        stateLock.lock()
        serverTask = task
        activePort = port
        activeHost = host
        activeRunID = runID
        running = true
        stateLock.unlock()

        Log.app.info("Bridge listening on \(host):\(port)")
    }

    private func markStopped(runID: UUID) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeRunID == runID else { return }
        serverTask = nil
        activePort = nil
        activeHost = nil
        activeRunID = nil
        running = false
    }

    private func makeApplication(host: String, port: Int) -> Application<RouterResponder<BridgeRequestContext>> {
        let service = self.service
        let router = Router(context: BridgeRequestContext.self)

        router.get("v1/health") { request, context async -> Response in
            await Self.authorizedRecordedRequest(
                .health,
                request: request,
                context: context
            ) {
                let payload = await service.health()
                return Self.jsonResponse(payload)
            }
        }

        router.get("v1/pairing") { request, context async -> Response in
            await Self.authorizedRecordedRequest(
                .pairing,
                request: request,
                context: context
            ) {
                let payload = BridgePairingPayload.current()
                return Self.jsonResponse(payload)
            }
        }

        router.get("v1/settings") { request, context async -> Response in
            await Self.authorizedRecordedRequest(
                .settingsRead,
                request: request,
                context: context
            ) {
                let payload = await service.settings()
                return Self.jsonResponse(payload)
            }
        }

        router.post("v1/settings") { request, context async -> Response in
            await Self.authorizedDecodedRecordedRequest(
                .settingsWrite,
                request: request,
                context: context,
                decode: { try await Self.decodeJSON(BridgeSettingsUpdateRequest.self, from: request) }
            ) { payload in
                let response = try await service.updateSettings(payload)
                return Self.jsonResponse(response)
            }
        }

        router.post("v1/dictate") { request, context async -> Response in
            await Self.authorizedDecodedRecordedRequest(
                .dictate,
                request: request,
                context: context,
                decode: { try await Self.decodeDictateRequest(from: request) },
                metadata: { BridgeRequestMetadata(appName: $0.appName, bundleID: $0.bundleID) }
            ) { payload in
                let response = try await service.dictate(payload)
                return Self.jsonResponse(response)
            }
        }

        router.post("v1/restyle") { request, context async -> Response in
            await Self.authorizedDecodedRecordedRequest(
                .restyle,
                request: request,
                context: context,
                decode: { try await Self.decodeJSON(BridgeRestyleRequest.self, from: request) },
                metadata: { BridgeRequestMetadata(appName: $0.appName, bundleID: $0.bundleID) }
            ) { payload in
                let response = try await service.restyle(payload)
                return Self.jsonResponse(response)
            }
        }

        router.post("v1/edit-text") { request, context async -> Response in
            await Self.authorizedDecodedRecordedRequest(
                .editText,
                request: request,
                context: context,
                decode: { try await Self.decodeJSON(BridgeTextEditRequest.self, from: request) },
                metadata: { BridgeRequestMetadata(appName: $0.appName, bundleID: $0.bundleID) }
            ) { payload in
                let response = try await service.editText(payload)
                return Self.jsonResponse(response)
            }
        }

        return Application(
            router: router,
            configuration: .init(
                address: .hostname(host, port: port),
                serverName: nil,
                reuseAddress: true
            )
        )
    }

    private static func authorizedRecordedRequest(
        _ endpoint: BridgeRequestEndpoint,
        request: Request,
        context: BridgeRequestContext,
        operation: () async throws -> Response
    ) async -> Response {
        let startedAt = Date()
        guard isAuthorized(request) else {
            return emptyResponse(status: 404, reason: "Not Found")
        }
        guard hasClientIdentity(request) else {
            return missingClientIdentityResponse()
        }

        do {
            let response = try await operation()
            recordRequest(endpoint, request: request, context: context, statusCode: 200, startedAt: startedAt)
            return response
        } catch {
            recordRequest(
                endpoint,
                request: request,
                context: context,
                statusCode: statusCode(for: error),
                startedAt: startedAt
            )
            return errorResponse(error)
        }
    }

    private static func authorizedDecodedRecordedRequest<Payload>(
        _ endpoint: BridgeRequestEndpoint,
        request: Request,
        context: BridgeRequestContext,
        decode: () async throws -> Payload,
        metadata: (Payload) -> BridgeRequestMetadata = { _ in .empty },
        operation: (Payload) async throws -> Response
    ) async -> Response {
        let startedAt = Date()
        guard isAuthorized(request) else {
            return emptyResponse(status: 404, reason: "Not Found")
        }
        guard hasClientIdentity(request) else {
            return missingClientIdentityResponse()
        }

        do {
            let payload = try await decode()
            let requestMetadata = metadata(payload)
            do {
                let response = try await operation(payload)
                recordRequest(
                    endpoint,
                    request: request,
                    context: context,
                    statusCode: 200,
                    startedAt: startedAt,
                    metadata: requestMetadata
                )
                return response
            } catch {
                recordRequest(
                    endpoint,
                    request: request,
                    context: context,
                    statusCode: statusCode(for: error),
                    startedAt: startedAt,
                    metadata: requestMetadata
                )
                return errorResponse(error)
            }
        } catch {
            recordRequest(
                endpoint,
                request: request,
                context: context,
                statusCode: statusCode(for: error),
                startedAt: startedAt
            )
            return errorResponse(error)
        }
    }

    private static func recordRequest(
        _ endpoint: BridgeRequestEndpoint,
        request: Request,
        context: BridgeRequestContext,
        statusCode: Int,
        startedAt: Date,
        metadata: BridgeRequestMetadata = .empty
    ) {
        let finishedAt = Date()
        let latencyMs = max(0, Int(finishedAt.timeIntervalSince(startedAt) * 1000))
        guard let clientIdentityID = cleanHeader(request.headers[.typeformeClientID], maxLength: 96) else {
            return
        }
        let trustForwardedHeaders = shouldTrustForwardedHeaders(from: context.remoteAddress)
        let activity = BridgeClientRequestActivity(
            endpoint: endpoint,
            clientHost: context.remoteAddress?.ipAddress ?? "unknown",
            clientPort: context.remoteAddress?.port,
            userAgent: cleanHeader(request.headers[.userAgent], maxLength: 160),
            clientIdentityID: clientIdentityID,
            statusCode: statusCode,
            occurredAt: finishedAt,
            latencyMs: latencyMs,
            appName: metadata.appName,
            bundleID: metadata.bundleID,
            clientDisplayName: cleanHeader(request.headers[.typeformeClientName], maxLength: 80),
            clientPlatform: cleanHeader(request.headers[.typeformeClientPlatform], maxLength: 32),
            clientBundleID: cleanHeader(request.headers[.typeformeClientBundleID], maxLength: 120),
            forwardedClientIP: trustForwardedHeaders ? forwardedClientIP(from: request) : nil,
            cloudflareRayID: trustForwardedHeaders ? cleanHeader(request.headers[.cfRay], maxLength: 80) : nil
        )
        BridgeConnectionStore.shared.record(activity)
    }

    private static func shouldTrustForwardedHeaders(from remoteAddress: SocketAddress?) -> Bool {
        guard AppSettings.bridgePublicEnabled else { return false }
        guard let ip = remoteAddress?.ipAddress else { return false }
        return ip == "127.0.0.1" || ip == "::1" || ip == "localhost"
    }

    private static func forwardedClientIP(from request: Request) -> String? {
        if let ip = cleanHeader(request.headers[.cfConnectingIP], maxLength: 80) {
            return ip
        }
        let firstForwardedValue = request.headers[.xForwardedFor]?
            .split(separator: ",", maxSplits: 1)
            .first
            .map(String.init)
        return cleanHeader(firstForwardedValue, maxLength: 80)
    }

    private static func cleanHeader(_ value: String?, maxLength: Int) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }

    private static func isAuthorized(_ request: Request) -> Bool {
        let token = AppSettings.bridgeAuthToken
        let auth = request.headers[.authorization] ?? ""
        guard auth.hasPrefix("Bearer ") else { return false }
        return constantTimeEquals(String(auth.dropFirst(7)), token)
    }

    private static func hasClientIdentity(_ request: Request) -> Bool {
        cleanHeader(request.headers[.typeformeClientID], maxLength: 96) != nil
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from request: Request) async throws -> T {
        guard request.headers[.contentType]?.lowercased().contains("application/json") == true else {
            throw BridgeServiceError.invalidRequest("Content-Type must be application/json")
        }
        let body = try await request.body.collect(upTo: Self.maxBodyBytes)
        return try BridgeJSON.decode(T.self, from: Data(body.readableBytesView))
    }

    private static func jsonResponse<T: Encodable>(_ value: T, status: Int = 200, reason: String = "OK") -> Response {
        guard let data = try? BridgeJSON.encodeSorted(value) else {
            return errorResponse(500, "Internal Server Error", "Could not encode response")
        }
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        headers[.cacheControl] = "no-store"
        return Response(
            status: HTTPResponse.Status(code: status, reasonPhrase: reason),
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }

    private static func errorResponse(_ error: Error) -> Response {
        if let bridgeError = error as? BridgeServiceError {
            return errorResponse(400, "Bad Request", bridgeError.localizedDescription)
        }
        if let multipartError = error as? BridgeMultipartError {
            return errorResponse(400, "Bad Request", multipartError.localizedDescription)
        }
        if error is DecodingError {
            return errorResponse(400, "Bad Request", "Invalid JSON request")
        }
        return errorResponse(500, "Internal Server Error", error.localizedDescription)
    }

    private static func statusCode(for error: Error) -> Int {
        if error is BridgeServiceError || error is BridgeMultipartError || error is DecodingError {
            return 400
        }
        return 500
    }

    private static func errorResponse(_ status: Int, _ reason: String, _ message: String) -> Response {
        jsonResponse(BridgeErrorResponse(error: message), status: status, reason: reason)
    }

    private static func missingClientIdentityResponse() -> Response {
        errorResponse(400, "Bad Request", "Missing Typeforme client identity")
    }

    private static func emptyResponse(status: Int, reason: String) -> Response {
        Response(status: HTTPResponse.Status(code: status, reasonPhrase: reason))
    }

    private static func decodeDictateRequest(from request: Request) async throws -> BridgeDictateRequest {
        let contentType = request.headers[.contentType] ?? ""
        let parser = try BridgeMultipart.StreamingFormDataParser(
            contentType: contentType,
            maxBodyBytes: Self.maxBodyBytes,
            maxHeaderBytes: Self.maxMultipartHeaderBytes,
            maxFieldBytes: Self.maxMultipartFieldBytes,
            audioDirectory: AppPaths.bridgeDir
        )
        var tempAudioURL: URL?
        do {
            for try await chunk in request.body {
                try parser.append(Data(chunk.readableBytesView))
            }
            let form = try parser.finish()
            let fields = form.fields
            tempAudioURL = form.audioFileURL

            guard let tempAudioURL,
                  ((try? FileManager.default.attributesOfItem(atPath: tempAudioURL.path)[.size] as? NSNumber)?.intValue ?? 0) > 0
            else {
                throw BridgeServiceError.invalidAudio
            }

            return BridgeDictateRequest(
                audioFileURL: tempAudioURL,
                audioExtension: fields["audio_extension"] ?? form.audioFilename.flatMap(fileExtension),
                languageIDs: parseLanguageIDs(fields["language_ids"]),
                languageMode: fields["language_mode"],
                correctionMode: fields["correction_mode"],
                appName: fields["app_name"],
                bundleID: fields["bundle_id"],
                appCategory: fields["app_category"],
                contextBefore: fields["context_before"],
                contextAfter: fields["context_after"],
                includeRawTranscript: parseBool(fields["include_raw_transcript"])
            )
        } catch {
            parser.cleanup()
            if let tempAudioURL {
                try? FileManager.default.removeItem(at: tempAudioURL)
            }
            throw error
        }
    }

    private static func parseLanguageIDs(_ raw: String?) -> [String]? {
        guard let raw, !raw.isEmpty else { return nil }
        if let data = raw.data(using: .utf8),
           let ids = try? BridgeJSON.decode([String].self, from: data) {
            return ids
        }
        return raw
            .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func parseBool(_ raw: String?) -> Bool? {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return nil }
        return ["1", "true", "yes", "y"].contains(raw)
    }

    private static func fileExtension(_ filename: String) -> String? {
        let ext = URL(fileURLWithPath: filename).pathExtension
        return ext.isEmpty ? nil : ext
    }
}
