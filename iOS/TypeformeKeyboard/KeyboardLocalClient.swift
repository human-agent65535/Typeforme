import Foundation
import OSLog

private let keyboardLocalClientLog = Logger(
    subsystem: TypeformeBundleConfiguration.keyboardBundleIdentifier,
    category: "local-client"
)

enum KeyboardLocalProbeResult: Sendable {
    case unreachable
    case reachable(status: KeyboardBridgeStatus?)
}

/// Keyboard-side client for the host's loopback WebSocket bridge.
///
/// Status is a host-pushed stream. Commands stay on dedicated connections so
/// command acks never interleave with pushed status frames.
actor KeyboardLocalClient {
    fileprivate static let statusStreamReceiveTimeout: TimeInterval = 6.0

    private let url = URL(string: "ws://127.0.0.1:18082/keyboard")!
    private let session = URLSession(configuration: .ephemeral)
    private var statusStreamTask: URLSessionWebSocketTask?
    private var statusStreamReceiveTask: Task<Void, Never>?
    private var statusStreamBridgeToken: String?
    private var statusStreamGeneration: UInt64 = 0
    /// Bumped by shutdown(). In-flight sends snapshot this at entry so a
    /// failure caused by shutdown cancelling the status socket is not
    /// "healed" by a fresh dial, and a socket dialed across a shutdown is
    /// never kept alive.
    private var shutdownGeneration: UInt64 = 0

    func startStatusStream(
        bridgeToken: String?,
        onStatus: @escaping @Sendable (KeyboardBridgeStatus) async -> Void,
        onFailure: @escaping @Sendable (Error) async -> Void,
        force: Bool = false
    ) {
        guard let bridgeToken,
              !bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            keyboardLocalClientLog.notice("status stream skipped: missing bridge token")
            KeyboardDiagnosticEventLog.record(
                source: "keyboard-local-client",
                event: "status_stream_missing_token"
            )
            stopStatusStream()
            Task { await onFailure(URLError(.userAuthenticationRequired)) }
            return
        }

        if !force, statusStreamTask != nil, statusStreamBridgeToken == bridgeToken {
            keyboardLocalClientLog.debug("status stream reused")
            return
        }

        stopStatusStream()
        statusStreamGeneration &+= 1
        let generation = statusStreamGeneration
        let shutdownAtStart = shutdownGeneration
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 1.0
        let task = session.webSocketTask(with: urlRequest)
        task.maximumMessageSize = 1 * 1024 * 1024
        statusStreamTask = task
        statusStreamBridgeToken = bridgeToken
        keyboardLocalClientLog.notice("status stream starting generation=\(generation, privacy: .public) force=\(force, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "keyboard-local-client",
            event: "status_stream_starting",
            fields: [
                "generation": "\(generation)",
                "force": "\(force)",
            ]
        )
        task.resume()

        statusStreamReceiveTask = Task { [weak self, task, bridgeToken] in
            do {
                try await keyboardBridgeStatusStream(
                    on: task,
                    bridgeToken: bridgeToken,
                    timeout: 1.5,
                    onStatus: onStatus
                )
            } catch {
                if error is CancellationError, Task.isCancelled {
                    return
                }
                keyboardLocalClientLog.notice("status stream failed generation=\(generation, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "keyboard-local-client",
                    event: "status_stream_failed",
                    fields: [
                        "generation": "\(generation)",
                        "error": error.localizedDescription,
                    ]
                )
                guard let self else { return }
                let shouldReport = await self.finishStatusStream(
                    generation: generation,
                    task: task,
                    shutdownAtStart: shutdownAtStart
                )
                if shouldReport {
                    await onFailure(error)
                }
            }
        }
    }

    func statusSnapshot(bridgeToken: String?, timeout: TimeInterval) async throws -> KeyboardBridgeStatus {
        guard let bridgeToken,
              !bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            keyboardLocalClientLog.notice("status snapshot skipped: missing bridge token")
            throw URLError(.userAuthenticationRequired)
        }
        let request = KeyboardLocalBridgeRequest.statusSnapshot()
        let generation = shutdownGeneration
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = timeout
        let task = session.webSocketTask(with: urlRequest)
        task.maximumMessageSize = 1 * 1024 * 1024
        keyboardLocalClientLog.notice("status snapshot starting timeout_ms=\(Int(timeout * 1_000), privacy: .public)")
        task.resume()
        do {
            let status = try await keyboardBridgeCommandRoundTrip(
                request,
                on: task,
                verifyHelloWith: bridgeToken,
                timeout: timeout
            )
            task.cancel(with: .normalClosure, reason: nil)
            guard shutdownGeneration == generation else {
                keyboardLocalClientLog.notice("status snapshot cancelled by client shutdown")
                throw URLError(.cancelled)
            }
            keyboardLocalClientLog.notice("status snapshot succeeded state=\(status.state.rawValue, privacy: .public) command_id=\(status.commandID ?? "none", privacy: .public)")
            return status
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            keyboardLocalClientLog.notice("status snapshot failed error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func probeStatus(
        bridgeToken: String?,
        helloTimeout: TimeInterval,
        statusTimeout: TimeInterval
    ) async -> KeyboardLocalProbeResult {
        guard let bridgeToken,
              !bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            keyboardLocalClientLog.notice("probe status skipped: missing bridge token")
            KeyboardDiagnosticEventLog.record(
                source: "keyboard-local-client",
                event: "probe_status_missing_token"
            )
            return .unreachable
        }
        let generation = shutdownGeneration
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = max(helloTimeout + statusTimeout + 0.2, 0.2)
        let task = session.webSocketTask(with: urlRequest)
        task.maximumMessageSize = 1 * 1024 * 1024
        keyboardLocalClientLog.notice("probe status starting hello_timeout_ms=\(Int(helloTimeout * 1_000), privacy: .public) status_timeout_ms=\(Int(statusTimeout * 1_000), privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "keyboard-local-client",
            event: "probe_status_starting",
            fields: [
                "hello_timeout_ms": "\(Int(helloTimeout * 1_000))",
                "status_timeout_ms": "\(Int(statusTimeout * 1_000))",
            ]
        )
        task.resume()

        do {
            let helloData = try messageData(try await receiveMessage(on: task, timeout: helloTimeout))
            let hello = try JSONDecoder().decode(KeyboardLocalBridgeHello.self, from: helloData)
            guard KeyboardLocalBridgeAuth.verifyServerHello(hello, bridgeToken: bridgeToken),
                  shutdownGeneration == generation
            else {
                task.cancel(with: .normalClosure, reason: nil)
                keyboardLocalClientLog.notice("probe status unreachable: hello verification failed or client shutdown")
                KeyboardDiagnosticEventLog.record(
                    source: "keyboard-local-client",
                    event: "probe_status_unreachable_bad_hello"
                )
                return .unreachable
            }
            keyboardLocalClientLog.notice("probe status hello verified")
            KeyboardDiagnosticEventLog.record(
                source: "keyboard-local-client",
                event: "probe_status_hello_verified"
            )

            do {
                guard let request = KeyboardLocalBridgeRequest.statusSnapshot().authenticated(
                    bridgeToken: bridgeToken,
                    serverNonce: hello.nonce
                ) else {
                    throw URLError(.userAuthenticationRequired)
                }
                let payload = try JSONEncoder().encode(request)
                try await task.send(.data(payload))
                let message = try await receiveMessage(on: task, timeout: statusTimeout)
                let status = try JSONDecoder().decode(KeyboardBridgeStatus.self, from: try messageData(message))
                task.cancel(with: .normalClosure, reason: nil)
                guard shutdownGeneration == generation else { return .unreachable }
                keyboardLocalClientLog.notice("probe status succeeded state=\(status.state.rawValue, privacy: .public) command_id=\(status.commandID ?? "none", privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "keyboard-local-client",
                    event: "probe_status_succeeded",
                    fields: [
                        "state": status.state.rawValue,
                        "command_id": status.commandID ?? "none",
                    ]
                )
                return .reachable(status: status)
            } catch {
                task.cancel(with: .normalClosure, reason: nil)
                guard shutdownGeneration == generation else { return .unreachable }
                keyboardLocalClientLog.notice("probe status reachable without status error=\(error.localizedDescription, privacy: .public)")
                KeyboardDiagnosticEventLog.record(
                    source: "keyboard-local-client",
                    event: "probe_status_reachable_without_status",
                    fields: ["error": error.localizedDescription]
                )
                return .reachable(status: nil)
            }
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            keyboardLocalClientLog.notice("probe status unreachable: hello failed error=\(error.localizedDescription, privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "keyboard-local-client",
                event: "probe_status_unreachable_hello_failed",
                fields: ["error": error.localizedDescription]
            )
            return .unreachable
        }
    }

    func send(_ command: KeyboardBridgeCommand, bridgeToken: String?, timeout: TimeInterval) async throws -> KeyboardBridgeStatus {
        guard let bridgeToken,
              !bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            keyboardLocalClientLog.notice("command send skipped: missing bridge token action=\(command.action.rawValue, privacy: .public) command_id=\(command.id, privacy: .public)")
            throw URLError(.userAuthenticationRequired)
        }
        let request = KeyboardLocalBridgeRequest.command(command)
        let generation = shutdownGeneration
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = timeout
        let task = session.webSocketTask(with: urlRequest)
        task.maximumMessageSize = 1 * 1024 * 1024
        keyboardLocalClientLog.notice("command send starting action=\(command.action.rawValue, privacy: .public) command_id=\(command.id, privacy: .public) timeout_ms=\(Int(timeout * 1_000), privacy: .public)")
        task.resume()
        do {
            let status = try await keyboardBridgeCommandRoundTrip(
                request,
                on: task,
                verifyHelloWith: bridgeToken,
                timeout: timeout
            )
            task.cancel(with: .normalClosure, reason: nil)
            guard shutdownGeneration == generation else {
                keyboardLocalClientLog.notice("command send cancelled by client shutdown action=\(command.action.rawValue, privacy: .public) command_id=\(command.id, privacy: .public)")
                throw URLError(.cancelled)
            }
            keyboardLocalClientLog.notice("command send succeeded action=\(command.action.rawValue, privacy: .public) command_id=\(command.id, privacy: .public) state=\(status.state.rawValue, privacy: .public) status_command_id=\(status.commandID ?? "none", privacy: .public)")
            return status
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            keyboardLocalClientLog.notice("command send failed action=\(command.action.rawValue, privacy: .public) command_id=\(command.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Closes the pushed status stream. Called when the keyboard disappears;
    /// the host drops its side on cancel.
    func shutdown() {
        shutdownGeneration &+= 1
        keyboardLocalClientLog.notice("local client shutdown generation=\(self.shutdownGeneration, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "keyboard-local-client",
            event: "shutdown",
            fields: ["generation": "\(shutdownGeneration)"]
        )
        stopStatusStream()
    }

    private func stopStatusStream() {
        statusStreamReceiveTask?.cancel()
        statusStreamReceiveTask = nil
        statusStreamTask?.cancel(with: .normalClosure, reason: nil)
        statusStreamTask = nil
        statusStreamBridgeToken = nil
    }

    private func finishStatusStream(
        generation: UInt64,
        task: URLSessionWebSocketTask,
        shutdownAtStart: UInt64
    ) -> Bool {
        guard statusStreamGeneration == generation,
              statusStreamTask === task
        else {
            task.cancel(with: .normalClosure, reason: nil)
            return false
        }
        stopStatusStream()
        return shutdownGeneration == shutdownAtStart
    }
}

private func keyboardBridgeStatusStream(
    on task: URLSessionWebSocketTask,
    bridgeToken: String,
    timeout: TimeInterval,
    onStatus: @escaping @Sendable (KeyboardBridgeStatus) async -> Void
) async throws {
    let helloData = try messageData(try await receiveMessage(on: task, timeout: timeout))
    let hello = try JSONDecoder().decode(KeyboardLocalBridgeHello.self, from: helloData)
    guard KeyboardLocalBridgeAuth.verifyServerHello(hello, bridgeToken: bridgeToken) else {
        throw URLError(.userAuthenticationRequired)
    }
    guard let request = KeyboardLocalBridgeRequest.statusStream().authenticated(
        bridgeToken: bridgeToken,
        serverNonce: hello.nonce
    ) else {
        throw URLError(.userAuthenticationRequired)
    }
    let payload = try JSONEncoder().encode(request)
    try await task.send(.data(payload))
    let firstMessage = try await receiveMessage(on: task, timeout: timeout)
    let firstStatus = try JSONDecoder().decode(KeyboardBridgeStatus.self, from: try messageData(firstMessage))
    await onStatus(firstStatus)
    while !Task.isCancelled {
        let message = try await receiveMessage(on: task, timeout: KeyboardLocalClient.statusStreamReceiveTimeout)
        let status = try JSONDecoder().decode(KeyboardBridgeStatus.self, from: try messageData(message))
        await onStatus(status)
    }
}

private func receiveMessage(
    on task: URLSessionWebSocketTask,
    timeout: TimeInterval
) async throws -> URLSessionWebSocketTask.Message {
    try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
        group.addTask {
            try await task.receive()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(timeout, 0.05) * 1_000_000_000))
            task.cancel(with: .normalClosure, reason: nil)
            throw URLError(.timedOut)
        }
        guard let message = try await group.next() else {
            throw URLError(.unknown)
        }
        group.cancelAll()
        return message
    }
}

private func keyboardBridgeCommandRoundTrip(
    _ request: KeyboardLocalBridgeRequest,
    on task: URLSessionWebSocketTask,
    verifyHelloWith helloBridgeToken: String,
    timeout: TimeInterval
) async throws -> KeyboardBridgeStatus {
    try await withThrowingTaskGroup(of: KeyboardBridgeStatus.self) { group in
        group.addTask {
            let helloData = try messageData(try await task.receive())
            let hello = try JSONDecoder().decode(KeyboardLocalBridgeHello.self, from: helloData)
            guard KeyboardLocalBridgeAuth.verifyServerHello(hello, bridgeToken: helloBridgeToken) else {
                throw URLError(.userAuthenticationRequired)
            }
            guard let authenticatedRequest = request.authenticated(
                bridgeToken: helloBridgeToken,
                serverNonce: hello.nonce
            ) else {
                throw URLError(.userAuthenticationRequired)
            }
            let payload = try JSONEncoder().encode(authenticatedRequest)
            try await task.send(.data(payload))
            let message = try await task.receive()
            return try JSONDecoder().decode(KeyboardBridgeStatus.self, from: try messageData(message))
        }
        group.addTask {
            // Sleep throws CancellationError when the round trip already won,
            // leaving the socket untouched for reuse.
            try await Task.sleep(nanoseconds: UInt64(max(timeout, 0.05) * 1_000_000_000))
            // Real timeout: force the pending receive to fail so the group
            // settles instead of waiting on a hung socket.
            task.cancel(with: .normalClosure, reason: nil)
            throw URLError(.timedOut)
        }
        guard let result = try await group.next() else {
            throw URLError(.unknown)
        }
        group.cancelAll()
        return result
    }
}

private func messageData(_ message: URLSessionWebSocketTask.Message) throws -> Data {
    switch message {
    case .data(let responseData):
        return responseData
    case .string(let responseString):
        return Data(responseString.utf8)
    @unknown default:
        throw URLError(.cannotDecodeContentData)
    }
}

extension KeyboardBridgeCommandAction {
    var requestTimeout: TimeInterval {
        switch self {
        case .start:
            return 1.0
        case .configure, .cancel:
            return 1.2
        case .stop:
            // `.stop` only waits for the host to acknowledge receipt. The
            // host publishes transcription progress/result asynchronously.
            return 1.5
        case .refineText:
            return 30
        }
    }
}
