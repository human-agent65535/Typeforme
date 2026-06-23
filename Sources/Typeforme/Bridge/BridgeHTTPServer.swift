import Foundation
import Hummingbird
import HummingbirdWebSocket
import HTTPTypes
import NIOCore

private struct BridgeRequestContext: RequestContext, RemoteAddressRequestContext, WebSocketRequestContext {
    var coreContext: CoreRequestContextStorage
    let webSocket: WebSocketHandlerReference<Self>
    let remoteAddress: SocketAddress?

    init(source: ApplicationRequestContextSource) {
        coreContext = CoreRequestContextStorage(source: source)
        webSocket = WebSocketHandlerReference()
        remoteAddress = source.channel.remoteAddress
    }
}

private struct BridgeRequestMetadata: Sendable {
    var appName: String?
    var bundleID: String?

    static let empty = BridgeRequestMetadata()
}

private actor BridgeLivePreviewWebSocketWriter {
    private var lastText: String?
    private var sentFinal = false

    func send(
        _ event: BridgeLivePreviewEvent,
        outbound: WebSocketOutboundWriter
    ) async throws {
        guard !sentFinal else { return }
        if let text = event.text, !event.isFinal {
            guard text != lastText else { return }
            lastText = text
        }
        if event.isFinal {
            sentFinal = true
        }
        let data = try BridgeJSON.encodeSorted(event)
        guard let json = String(data: data, encoding: .utf8) else {
            throw BridgeServiceError.invalidRequest("Could not encode live preview WebSocket event")
        }
        try await outbound.write(.text(json))
        Log.bridge.debug(
            "Bridge live preview socket send session=\(String(event.sessionID.prefix(8)), privacy: .public) final=\(event.isFinal, privacy: .public) text_chars=\(event.text?.count ?? 0, privacy: .public)"
        )
    }

    func sendFinal(
        _ response: BridgeLivePreviewFinishResponse,
        outbound: WebSocketOutboundWriter
    ) async throws {
        let event = BridgeLivePreviewEvent(
            sessionID: response.sessionID,
            provider: "nvidia-nemotron-asr",
            text: response.text,
            isFinal: true,
            updatedAt: response.finishedAt
        )
        try await send(event, outbound: outbound)
    }
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
    private static let maxLivePreviewSocketMessageBytes = 512 * 1024
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
        publishStatus(.stopped)
    }

    private func publishStatus(_ status: BridgeServerStatusStore.Status) {
        Task { @MainActor in
            BridgeServerStatusStore.shared.set(status)
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

        // Mark the run active and publish .running BEFORE spawning the server
        // task: a fast bind failure checks `isActiveRun` and must find this
        // run registered, and its .failed publish must come after .running.
        stateLock.lock()
        activePort = port
        activeHost = host
        activeRunID = runID
        running = true
        stateLock.unlock()
        publishStatus(.running(host: host, port: port))

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
                // Only the still-active run may report failure — a stale run
                // dying during a restart must not overwrite the new status.
                if let self, self.isActiveRun(runID) {
                    self.publishStatus(.failed(message: error.localizedDescription))
                }
            }
        }

        stateLock.lock()
        serverTask = task
        stateLock.unlock()

        Log.app.info("Bridge listening on \(host):\(port)")
    }

    private func isActiveRun(_ runID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeRunID == runID
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

        router.get("v1/jobs/:jobID/events") { request, context async -> Response in
            await Self.authorizedRecordedRequest(
                .jobEvents,
                request: request,
                context: context
            ) {
                let jobID = try context.parameters.require("jobID")
                return Self.jobEventsResponse(jobID: jobID)
            }
        }

        router.post("v1/live-preview/start") { request, context async -> Response in
            await Self.authorizedDecodedRecordedRequest(
                .livePreviewStart,
                request: request,
                context: context,
                decode: { try await Self.decodeJSON(BridgeLivePreviewStartRequest.self, from: request) },
                metadata: { BridgeRequestMetadata(appName: $0.appName, bundleID: $0.bundleID) }
            ) { payload in
                let response = try await service.startLivePreview(payload)
                return Self.jsonResponse(response)
            }
        }

        router.ws("v1/live-preview/:sessionID/socket") { request, context async throws -> RouterShouldUpgrade in
            guard Self.isAuthorized(request) else {
                Self.recordRequest(.livePreviewSocket, request: request, context: context, statusCode: 404, startedAt: Date())
                return .dontUpgrade
            }
            guard Self.hasClientIdentity(request) else {
                Self.recordRequest(.livePreviewSocket, request: request, context: context, statusCode: 400, startedAt: Date())
                return .dontUpgrade
            }
            Self.recordRequest(.livePreviewSocket, request: request, context: context, statusCode: 200, startedAt: Date())
            return .upgrade()
        } onUpgrade: { inbound, outbound, context in
            let sessionID = try context.requestContext.parameters.require("sessionID")
            try await Self.handleLivePreviewSocket(
                sessionID: sessionID,
                service: service,
                inbound: inbound,
                outbound: outbound
            )
        }

        router.post("v1/live-preview/:sessionID/finish") { request, context async -> Response in
            await Self.authorizedRecordedRequest(
                .livePreviewFinish,
                request: request,
                context: context
            ) {
                let sessionID = try context.parameters.require("sessionID")
                let response = try await service.finishLivePreview(sessionID: sessionID)
                return Self.jsonResponse(response)
            }
        }

        router.post("v1/refine") { request, context async -> Response in
            await Self.authorizedDecodedRecordedRequest(
                .refine,
                request: request,
                context: context,
                decode: { try await Self.decodeJSON(BridgeRefineRequest.self, from: request) },
                metadata: { BridgeRequestMetadata(appName: $0.appName, bundleID: $0.bundleID) }
            ) { payload in
                let response = try await service.refine(payload)
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
            server: .http1WebSocketUpgrade(webSocketRouter: router),
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
        shouldTrustForwardedHeaders(
            remoteIP: remoteAddress?.ipAddress,
            publicBridgeEnabled: AppSettings.bridgePublicEnabled,
            lanBridgeEnabled: AppSettings.bridgeLANEnabled
        )
    }

    static func shouldTrustForwardedHeaders(
        remoteIP: String?,
        publicBridgeEnabled: Bool,
        lanBridgeEnabled: Bool
    ) -> Bool {
        guard publicBridgeEnabled, let ip = cleanHeader(remoteIP, maxLength: 80) else { return false }
        if isLoopbackAddress(ip) { return true }

        // A LAN-hosted cloudflared connector reaches Bridge from its LAN address.
        return lanBridgeEnabled && isPrivateLANAddress(ip)
    }

    private static func isLoopbackAddress(_ ip: String) -> Bool {
        ip == "127.0.0.1" || ip == "::1" || ip == "localhost"
    }

    private static func isPrivateLANAddress(_ ip: String) -> Bool {
        if let octets = ipv4Octets(ip) {
            if octets[0] == 10 { return true }
            if octets[0] == 172 { return (16...31).contains(octets[1]) }
            if octets[0] == 192 { return octets[1] == 168 }
            return false
        }

        let lowercasedIP = ip.lowercased()
        return lowercasedIP.hasPrefix("fc")
            || lowercasedIP.hasPrefix("fd")
            || lowercasedIP.hasPrefix("fe80:")
    }

    private static func ipv4Octets(_ ip: String) -> [Int]? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard let value = Int(part), (0...255).contains(value) else { return nil }
            octets.append(value)
        }
        return octets
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

    private static func handleLivePreviewSocket(
        sessionID: String,
        service: BridgeService,
        inbound: WebSocketInboundStream,
        outbound: WebSocketOutboundWriter
    ) async throws {
        let process = try await service.livePreviewAudioProcess(sessionID: sessionID)
        let writer = BridgeLivePreviewWebSocketWriter()
        let socketOpenedAt = Date()
        let socketLogID = String(sessionID.prefix(8))
        Log.bridge.notice("Bridge live preview socket opened session=\(socketLogID, privacy: .public)")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let stream = await BridgeLivePreviewEventCenter.shared.subscribe(sessionID: sessionID)
                for await event in stream where !event.isFinal {
                    try await writer.send(event, outbound: outbound)
                }
            }

            group.addTask {
                var receivedSamples = 0
                var nextAudioLogSampleCount = 16_000
                var firstAudioLogged = false
                do {
                    for try await message in inbound.messages(maxSize: Self.maxLivePreviewSocketMessageBytes) {
                        switch message {
                        case .binary(let buffer):
                            let data = Data(buffer.readableBytesView)
                            guard !data.isEmpty, data.count % MemoryLayout<Float>.size == 0 else {
                                throw BridgeServiceError.invalidAudio
                            }
                            let sampleCount = data.count / MemoryLayout<Float>.size
                            receivedSamples += sampleCount
                            if !firstAudioLogged || receivedSamples >= nextAudioLogSampleCount {
                                let isFirst = !firstAudioLogged
                                firstAudioLogged = true
                                while receivedSamples >= nextAudioLogSampleCount {
                                    nextAudioLogSampleCount += 16_000
                                }
                                Log.bridge.debug(
                                    "Bridge live preview socket audio session=\(socketLogID, privacy: .public) first=\(isFirst, privacy: .public) bytes=\(data.count, privacy: .public) received_audio_ms=\(receivedSamples * 1_000 / 16_000, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: socketOpenedAt), privacy: .public)"
                                )
                            }
                            process.appendPCM16kMonoFloat32Data(data)
                            await service.touchLivePreviewSession(sessionID: sessionID)

                        case .text(let text):
                            let control = try BridgeJSON.decode(
                                BridgeLivePreviewSocketControl.self,
                                from: Data(text.utf8)
                            )
                            Log.bridge.notice(
                                "Bridge live preview socket control session=\(socketLogID, privacy: .public) type=\(control.type.rawValue, privacy: .public) received_audio_ms=\(receivedSamples * 1_000 / 16_000, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: socketOpenedAt), privacy: .public)"
                            )
                            switch control.type {
                            case .finish:
                                let response = try await service.finishLivePreview(sessionID: sessionID)
                                try await writer.sendFinal(response, outbound: outbound)
                                return
                            case .cancel:
                                await service.cancelLivePreview(sessionID: sessionID)
                                return
                            }
                        }
                    }
                    Log.bridge.notice(
                        "Bridge live preview socket closed by peer session=\(socketLogID, privacy: .public) received_audio_ms=\(receivedSamples * 1_000 / 16_000, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: socketOpenedAt), privacy: .public)"
                    )
                    await service.cancelLivePreview(sessionID: sessionID)
                } catch {
                    Log.bridge.notice(
                        "Bridge live preview socket error session=\(socketLogID, privacy: .public) received_audio_ms=\(receivedSamples * 1_000 / 16_000, privacy: .public) elapsed_ms=\(Self.elapsedMS(since: socketOpenedAt), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    await service.cancelLivePreview(sessionID: sessionID)
                    throw error
                }
            }

            guard try await group.next() != nil else { return }
            group.cancelAll()
        }
    }

    private static func elapsedMS(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
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

    private static func jobEventsResponse(jobID: String) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream; charset=utf-8"
        headers[.cacheControl] = "no-store"
        if let bufferingHeader = HTTPField.Name("X-Accel-Buffering") {
            headers[bufferingHeader] = "no"
        }

        let body = ResponseBody { writer in
            let stream = await BridgeJobStatusCenter.shared.subscribe(jobID: jobID)
            try await writer.write(ByteBuffer(string: ": typeforme job status\n\n"))
            for await event in stream {
                guard let data = try? BridgeJSON.encodeSorted(event),
                      let json = String(data: data, encoding: .utf8)
                else {
                    continue
                }
                var payload = "event: \(event.stage.rawValue)\n"
                payload += "data: \(json)\n\n"
                try await writer.write(ByteBuffer(string: payload))
                if event.stage.isTerminal {
                    break
                }
            }
            try await writer.finish(nil)
        }
        return Response(status: .ok, headers: headers, body: body)
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
                clientJobID: fields["client_job_id"],
                languageIDs: parseLanguageIDs(fields["language_ids"]),
                languageMode: fields["language_mode"],
                correctionMode: fields["correction_mode"],
                appName: fields["app_name"],
                bundleID: fields["bundle_id"],
                appCategory: fields["app_category"],
                contextBefore: fields["context_before"],
                contextAfter: fields["context_after"],
                includeRawTranscript: parseBool(fields["include_raw_transcript"]),
                alternateTranscript: fields["alternate_transcript"]
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
