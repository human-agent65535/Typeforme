import Foundation
import Network
import OSLog

private let keyboardLocalServerLog = Logger(
    subsystem: TypeformeBundleConfiguration.hostBundleIdentifier,
    category: "keyboard-local-server"
)

final class KeyboardLocalServer: @unchecked Sendable {
    static let port: UInt16 = 18082
    private static let maxMessageBytes = 1 * 1024 * 1024
    private static let statusStreamHeartbeatIntervalNanoseconds: UInt64 = 2_000_000_000

    var onCommand: ((KeyboardBridgeCommand) async -> KeyboardBridgeStatus)?
    var statusProvider: (() async -> KeyboardBridgeStatus)?
    var expectedTokenProvider: (() async -> String?)?

    private let queue = DispatchQueue(label: "\(TypeformeBundleConfiguration.hostBundleIdentifier).keyboard-server")
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var activeStatusStreams: [ObjectIdentifier: NWConnection] = [:]
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var statusStreamHeartbeatTask: Task<Void, Never>?
    private var generation: UInt = 0

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listener != nil
    }

    func start() throws {
        stateLock.lock()
        let alreadyRunning = listener != nil
        stateLock.unlock()
        guard !alreadyRunning else {
            keyboardLocalServerLog.debug("server start skipped: already running")
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "server_start_skipped_already_running"
            )
            return
        }

        let parameters = NWParameters.tcp
        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
        stateLock.lock()
        generation += 1
        let currentGeneration = generation
        self.listener = listener
        stateLock.unlock()
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection, generation: currentGeneration)
        }
        listener.stateUpdateHandler = { [weak self] state in
            keyboardLocalServerLog.notice("listener state=\(String(describing: state), privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "listener_state",
                fields: ["state": String(describing: state)]
            )
            if case .failed = state {
                self?.stop()
            }
        }
        listener.start(queue: queue)
        keyboardLocalServerLog.notice("server start requested generation=\(currentGeneration, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-local-server",
            event: "server_start_requested",
            fields: ["generation": "\(currentGeneration)"]
        )
    }

    func stop() {
        stateLock.lock()
        let currentListener = listener
        listener = nil
        generation += 1
        let connections = Array(activeConnections.values)
        activeConnections.removeAll()
        activeStatusStreams.removeAll()
        let tasks = Array(activeTasks.values)
        activeTasks.removeAll()
        let heartbeatTask = statusStreamHeartbeatTask
        statusStreamHeartbeatTask = nil
        stateLock.unlock()

        currentListener?.cancel()
        connections.forEach { $0.cancel() }
        tasks.forEach { $0.cancel() }
        heartbeatTask?.cancel()
        keyboardLocalServerLog.notice("server stopped connections=\(connections.count, privacy: .public) tasks=\(tasks.count, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-local-server",
            event: "server_stopped",
            fields: [
                "connections": "\(connections.count)",
                "tasks": "\(tasks.count)",
            ]
        )
    }

    private func handle(_ connection: NWConnection, generation: UInt) {
        guard Self.isLoopback(connection.endpoint) else {
            keyboardLocalServerLog.notice("connection rejected: non-loopback endpoint=\(String(describing: connection.endpoint), privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "connection_rejected_non_loopback",
                fields: ["endpoint": String(describing: connection.endpoint)]
            )
            connection.cancel()
            return
        }
        keyboardLocalServerLog.notice("connection accepted endpoint=\(String(describing: connection.endpoint), privacy: .public) generation=\(generation, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-local-server",
            event: "connection_accepted",
            fields: [
                "endpoint": String(describing: connection.endpoint),
                "generation": "\(generation)",
            ]
        )
        let id = ObjectIdentifier(connection)
        stateLock.lock()
        guard generation == self.generation, listener != nil else {
            stateLock.unlock()
            keyboardLocalServerLog.notice("connection cancelled: stale generation")
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "connection_cancelled_stale_generation"
            )
            connection.cancel()
            return
        }
        activeConnections[id] = connection
        stateLock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            guard case .cancelled = state else { return }
            self?.removeConnection(id)
        }
        connection.start(queue: queue)
        sendHelloThenReceive(from: connection, generation: generation)
    }

    private func sendHelloThenReceive(from connection: NWConnection, generation: UInt) {
        let taskID = UUID()
        let task = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            guard self.isCurrentGeneration(generation) else {
                connection.cancel()
                self.removeTask(taskID)
                return
            }
            guard let expectedToken = await self.expectedTokenProvider?(),
                  !expectedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let hello = KeyboardLocalBridgeAuth.makeServerHello(bridgeToken: expectedToken)
            else {
                keyboardLocalServerLog.notice("hello unavailable: missing expected token")
                KeyboardDiagnosticEventLog.record(
                    source: "host-local-server",
                    event: "hello_unavailable_missing_token"
                )
                self.send(
                    KeyboardBridgeStatus(state: .error, message: "Keyboard bridge unavailable"),
                    connection: connection
                )
                self.removeTask(taskID)
                return
            }
            guard !Task.isCancelled, self.isCurrentGeneration(generation) else {
                connection.cancel()
                self.removeTask(taskID)
                return
            }
            self.sendHello(hello, connection: connection) { [weak self] sent in
                guard let self else { return }
                guard sent, self.isCurrentGeneration(generation) else {
                    keyboardLocalServerLog.notice("hello send failed or stale generation sent=\(sent, privacy: .public)")
                    KeyboardDiagnosticEventLog.record(
                        source: "host-local-server",
                        event: "hello_send_failed_or_stale",
                        fields: ["sent": "\(sent)"]
                    )
                    connection.cancel()
                    self.removeTask(taskID)
                    return
                }
                keyboardLocalServerLog.notice("hello sent")
                KeyboardDiagnosticEventLog.record(
                    source: "host-local-server",
                    event: "hello_sent"
                )
                self.receiveMessage(from: connection, generation: generation, expectedToken: expectedToken)
                self.removeTask(taskID)
            }
        }
        storeTask(task, id: taskID, generation: generation)
    }

    func publishStatus(_ status: KeyboardBridgeStatus) {
        queue.async { [weak self] in
            guard let self else { return }
            let streams = self.statusStreamSnapshot()
            for connection in streams {
                self.send(status, connection: connection, closeAfterSend: false)
            }
        }
    }

    private func receiveMessage(from connection: NWConnection, generation: UInt, expectedToken: String) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }

            // Transport error or peer close — nothing left to answer.
            guard error == nil, let data else {
                keyboardLocalServerLog.notice("receive failed error=\(error?.localizedDescription ?? "none", privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "host-local-server",
                    event: "receive_failed",
                    fields: ["error": error?.localizedDescription ?? "none"]
                )
                connection.cancel()
                return
            }
            guard data.count <= Self.maxMessageBytes else {
                keyboardLocalServerLog.notice("request rejected: oversized bytes=\(data.count, privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "host-local-server",
                    event: "request_rejected_oversized",
                    fields: ["bytes": "\(data.count)"]
                )
                self.send(
                    KeyboardBridgeStatus(state: .error, message: "Bad keyboard bridge request"),
                    connection: connection
                )
                return
            }

            let request: KeyboardLocalBridgeRequest
            do {
                request = try JSONDecoder().decode(KeyboardLocalBridgeRequest.self, from: data)
            } catch {
                keyboardLocalServerLog.notice("request rejected: decode failed error=\(error.localizedDescription, privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "host-local-server",
                    event: "request_rejected_decode_failed",
                    fields: ["error": error.localizedDescription]
                )
                self.send(
                    KeyboardBridgeStatus(state: .error, message: "Invalid keyboard bridge request"),
                    connection: connection
                )
                return
            }

            let taskID = UUID()
            let task = Task { [weak self] in
                await Task.yield()
                guard let self else { return }
                guard self.isCurrentGeneration(generation) else {
                    connection.cancel()
                    self.removeTask(taskID)
                    return
                }
                let authorized = self.isAuthorized(request, expectedToken: expectedToken)
                let actionName = request.command?.action.rawValue ?? request.action.rawValue
                keyboardLocalServerLog.notice("request received action=\(actionName, privacy: .public) authorized=\(authorized, privacy: .public) command_id=\(request.command?.id ?? "none", privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "host-local-server",
                    event: "request_received",
                    fields: [
                        "action": actionName,
                        "authorized": "\(authorized)",
                        "command_id": request.command?.id ?? "none",
                    ]
                )
                let status = await self.status(for: request, authorized: authorized)
                keyboardLocalServerLog.notice("request status action=\(actionName, privacy: .public) authorized=\(authorized, privacy: .public) state=\(status.state.rawValue, privacy: .public) status_command_id=\(status.commandID ?? "none", privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "host-local-server",
                    event: "request_status",
                    fields: [
                        "action": actionName,
                        "authorized": "\(authorized)",
                        "state": status.state.rawValue,
                        "status_command_id": status.commandID ?? "none",
                    ]
                )
                guard !Task.isCancelled, self.isCurrentGeneration(generation) else {
                    connection.cancel()
                    self.removeTask(taskID)
                    return
                }
                if authorized {
                    switch request.action {
                    case .statusStream:
                        guard self.registerStatusStream(connection, generation: generation) else {
                            connection.cancel()
                            self.removeTask(taskID)
                            return
                        }
                        self.send(status, connection: connection, closeAfterSend: false)
                    case .statusSnapshot:
                        self.send(status, connection: connection, closeAfterSend: true)
                    case .command:
                        self.send(status, connection: connection, closeAfterSend: true)
                    }
                } else {
                    // Unauthorized peers get the error frame and a close —
                    // never a status stream.
                    self.send(status, connection: connection)
                }
                self.removeTask(taskID)
            }
            self.storeTask(task, id: taskID, generation: generation)
        }
    }

    private func status(for request: KeyboardLocalBridgeRequest, authorized: Bool) async -> KeyboardBridgeStatus {
        guard authorized else {
            return KeyboardBridgeStatus(state: .error, message: "Keyboard bridge unauthorized")
        }
        switch request.action {
        case .statusStream, .statusSnapshot:
            return await statusProvider?() ?? .idle
        case .command:
            guard let command = request.command else {
                return KeyboardBridgeStatus(state: .error, message: "Missing keyboard command")
            }
            return await onCommand?(command)
                ?? KeyboardBridgeStatus(state: .error, message: "Keyboard command handler is unavailable")
        }
    }

    private func isAuthorized(_ request: KeyboardLocalBridgeRequest, expectedToken: String) -> Bool {
        KeyboardLocalBridgeAuth.verifyClientProof(request.authentication, bridgeToken: expectedToken)
    }

    private func sendHello(
        _ hello: KeyboardLocalBridgeHello,
        connection: NWConnection,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        guard let data = try? JSONEncoder().encode(hello) else {
            connection.cancel()
            completion(false)
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "keyboard-bridge-hello", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            completion(error == nil)
        })
    }

    /// Sends one status frame. Status stream requests keep the socket open;
    /// snapshot and command requests close after the single response so command
    /// acks never interleave with pushed status frames.
    private func send(
        _ status: KeyboardBridgeStatus,
        connection: NWConnection,
        closeAfterSend: Bool = true
    ) {
        guard let data = try? JSONEncoder().encode(status) else {
            connection.cancel()
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "keyboard-bridge-status", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            guard error == nil, !closeAfterSend else {
                connection.cancel()
                return
            }
        })
    }

    private func registerStatusStream(_ connection: NWConnection, generation: UInt) -> Bool {
        let id = ObjectIdentifier(connection)
        stateLock.lock()
        guard generation == self.generation, listener != nil, activeConnections[id] != nil else {
            stateLock.unlock()
            return false
        }
        activeStatusStreams[id] = connection
        let shouldStartHeartbeat = statusStreamHeartbeatTask == nil
        stateLock.unlock()
        if shouldStartHeartbeat {
            startStatusStreamHeartbeatIfNeeded(generation: generation)
        }
        return true
    }

    private func startStatusStreamHeartbeatIfNeeded(generation: UInt) {
        stateLock.lock()
        guard generation == self.generation,
              listener != nil,
              statusStreamHeartbeatTask == nil,
              !activeStatusStreams.isEmpty
        else {
            stateLock.unlock()
            return
        }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.statusStreamHeartbeatIntervalNanoseconds)
                guard !Task.isCancelled, let self else { return }
                guard self.hasStatusStreams(generation: generation) else {
                    self.finishStatusStreamHeartbeat(generation: generation)
                    return
                }
                let status = await self.statusProvider?() ?? .idle
                self.publishStatus(status)
            }
        }
        statusStreamHeartbeatTask = task
        stateLock.unlock()
    }

    private func hasStatusStreams(generation: UInt) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == self.generation
            && listener != nil
            && !activeStatusStreams.isEmpty
    }

    private func finishStatusStreamHeartbeat(generation: UInt) {
        let shouldRestart: Bool
        stateLock.lock()
        if generation == self.generation {
            statusStreamHeartbeatTask = nil
            shouldRestart = listener != nil && !activeStatusStreams.isEmpty
        } else {
            shouldRestart = false
        }
        stateLock.unlock()
        if shouldRestart {
            startStatusStreamHeartbeatIfNeeded(generation: generation)
        }
    }

    private func statusStreamSnapshot() -> [NWConnection] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Array(activeStatusStreams.values)
    }

    private func storeTask(_ task: Task<Void, Never>, id: UUID, generation: UInt) {
        stateLock.lock()
        if generation == self.generation, listener != nil {
            activeTasks[id] = task
        } else {
            task.cancel()
        }
        stateLock.unlock()
    }

    private func removeTask(_ id: UUID) {
        stateLock.lock()
        activeTasks[id] = nil
        stateLock.unlock()
    }

    private func removeConnection(_ id: ObjectIdentifier) {
        stateLock.lock()
        activeConnections[id] = nil
        activeStatusStreams[id] = nil
        let heartbeatTask: Task<Void, Never>?
        if activeStatusStreams.isEmpty {
            heartbeatTask = statusStreamHeartbeatTask
            statusStreamHeartbeatTask = nil
        } else {
            heartbeatTask = nil
        }
        stateLock.unlock()
        heartbeatTask?.cancel()
    }

    private func isCurrentGeneration(_ generation: UInt) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == self.generation && listener != nil
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return String(describing: address) == "127.0.0.1"
        case .ipv6(let address):
            return String(describing: address) == "::1"
        case .name(let name, _):
            let normalized = name.lowercased()
            return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
        @unknown default:
            return false
        }
    }
}
