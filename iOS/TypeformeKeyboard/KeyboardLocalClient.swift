import Foundation

/// Keyboard-side client for the host's loopback WebSocket bridge.
///
/// Status polls run at ~8Hz while recording; dialing a fresh connection per
/// poll cost a TCP connect, WS upgrade, and HMAC hello round trip for every
/// sample. Status requests therefore reuse one verified connection — the host
/// keeps its side open after each response. Commands stay on dedicated
/// connections so a poll and a command can never interleave on one socket;
/// the actor's busy flag covers the remaining reentrancy window.
actor KeyboardLocalClient {
    private let url = URL(string: "ws://127.0.0.1:18082/keyboard")!
    private let session = URLSession(configuration: .ephemeral)
    private var pooledTask: URLSessionWebSocketTask?
    private var pooledBridgeToken: String?
    private var isPooledTaskBusy = false
    /// Bumped by shutdown(). In-flight sends snapshot this at entry so a
    /// failure caused by shutdown cancelling the pooled socket is not
    /// "healed" by a fresh dial, and a socket dialed across a shutdown is
    /// never re-pooled.
    private var shutdownGeneration: UInt64 = 0

    func status(bridgeToken: String?, timeout: TimeInterval = 0.45) async throws -> KeyboardBridgeStatus {
        try await send(action: .status, command: nil, bridgeToken: bridgeToken, timeout: timeout, reusesConnection: true)
    }

    func send(_ command: KeyboardBridgeCommand, bridgeToken: String?, timeout: TimeInterval) async throws -> KeyboardBridgeStatus {
        try await send(action: .command, command: command, bridgeToken: bridgeToken, timeout: timeout, reusesConnection: false)
    }

    /// Closes the pooled status connection. Called when status polling stops
    /// or the keyboard disappears; the host drops its side on cancel.
    func shutdown() {
        shutdownGeneration &+= 1
        discardPooledTask()
    }

    private func send(
        action: KeyboardLocalBridgeRequest.Action,
        command: KeyboardBridgeCommand?,
        bridgeToken: String?,
        timeout: TimeInterval,
        reusesConnection: Bool
    ) async throws -> KeyboardBridgeStatus {
        guard let bridgeToken,
              !bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw URLError(.userAuthenticationRequired)
        }
        let request: KeyboardLocalBridgeRequest
        switch action {
        case .status:
            request = .status(bridgeToken: bridgeToken)
        case .command:
            guard let command else { throw URLError(.badURL) }
            request = .command(command, bridgeToken: bridgeToken)
        }
        let generation = shutdownGeneration

        if reusesConnection,
           let task = pooledTask,
           pooledBridgeToken == bridgeToken,
           !isPooledTaskBusy {
            isPooledTaskBusy = true
            defer { isPooledTaskBusy = false }
            do {
                return try await keyboardBridgeRoundTrip(request, on: task, verifyHelloWith: nil, timeout: timeout)
            } catch {
                // Stale pooled socket (host listener restarted, timeout, close
                // mid-flight). Drop it and fall through to a fresh dial so one
                // dead connection never surfaces as a failed poll. Actors are
                // reentrant across awaits, so an overlapping call may have
                // replaced the pooled slot already — only tear down the slot
                // when it still holds this socket.
                if pooledTask === task {
                    discardPooledTask()
                } else {
                    task.cancel(with: .normalClosure, reason: nil)
                }
                // A failure caused by shutdown() cancelling this socket must
                // not fall through to a fresh dial — that would resurrect the
                // connection stopStatusPolling just asked us to close.
                guard shutdownGeneration == generation else { throw error }
            }
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = timeout
        let task = session.webSocketTask(with: urlRequest)
        task.maximumMessageSize = 1 * 1024 * 1024
        task.resume()
        do {
            let status = try await keyboardBridgeRoundTrip(
                request,
                on: task,
                verifyHelloWith: bridgeToken,
                timeout: timeout
            )
            // Don't pool across a shutdown: the poll result is still valid,
            // but the connection must not outlive stopStatusPolling.
            if reusesConnection, shutdownGeneration == generation {
                // Actor reentrancy: an overlapping call may have pooled its
                // own socket while this one awaited. Never hold two — close
                // the previous occupant before taking the slot.
                if let existing = pooledTask, existing !== task {
                    existing.cancel(with: .normalClosure, reason: nil)
                }
                pooledTask = task
                pooledBridgeToken = bridgeToken
            } else {
                task.cancel(with: .normalClosure, reason: nil)
            }
            return status
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            throw error
        }
    }

    private func discardPooledTask() {
        pooledTask?.cancel(with: .normalClosure, reason: nil)
        pooledTask = nil
        pooledBridgeToken = nil
        isPooledTaskBusy = false
    }
}

/// One request/response exchange. `verifyHelloWith` carries the bridge token
/// when the connection is fresh and the server's hello frame must still be
/// verified; nil for a pooled connection that already passed verification.
private func keyboardBridgeRoundTrip(
    _ request: KeyboardLocalBridgeRequest,
    on task: URLSessionWebSocketTask,
    verifyHelloWith helloBridgeToken: String?,
    timeout: TimeInterval
) async throws -> KeyboardBridgeStatus {
    try await withThrowingTaskGroup(of: KeyboardBridgeStatus.self) { group in
        group.addTask {
            if let helloBridgeToken {
                let helloData = try messageData(try await task.receive())
                let hello = try JSONDecoder().decode(KeyboardLocalBridgeHello.self, from: helloData)
                guard KeyboardLocalBridgeAuth.verifyServerHello(hello, bridgeToken: helloBridgeToken) else {
                    throw URLError(.userAuthenticationRequired)
                }
            }
            let payload = try JSONEncoder().encode(request)
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
        case .restyleText:
            return 30
        }
    }
}
