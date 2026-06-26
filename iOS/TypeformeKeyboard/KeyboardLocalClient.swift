import Foundation

/// Keyboard-side client for the host's loopback WebSocket bridge.
///
/// Status is a host-pushed stream. Commands stay on dedicated connections so
/// command acks never interleave with pushed status frames.
actor KeyboardLocalClient {
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
        onFailure: @escaping @Sendable (Error) async -> Void
    ) {
        guard let bridgeToken,
              !bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            stopStatusStream()
            Task { await onFailure(URLError(.userAuthenticationRequired)) }
            return
        }

        if statusStreamTask != nil, statusStreamBridgeToken == bridgeToken {
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
        task.resume()

        statusStreamReceiveTask = Task { [weak self, task, bridgeToken] in
            do {
                try await keyboardBridgeStatusStream(
                    on: task,
                    bridgeToken: bridgeToken,
                    onStatus: onStatus
                )
            } catch is CancellationError {
                return
            } catch {
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

    func send(_ command: KeyboardBridgeCommand, bridgeToken: String?, timeout: TimeInterval) async throws -> KeyboardBridgeStatus {
        guard let bridgeToken,
              !bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw URLError(.userAuthenticationRequired)
        }
        let request = KeyboardLocalBridgeRequest.command(command, bridgeToken: bridgeToken)
        let generation = shutdownGeneration
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = timeout
        let task = session.webSocketTask(with: urlRequest)
        task.maximumMessageSize = 1 * 1024 * 1024
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
                throw URLError(.cancelled)
            }
            return status
        } catch {
            task.cancel(with: .normalClosure, reason: nil)
            throw error
        }
    }

    /// Closes the pushed status stream. Called when the keyboard disappears;
    /// the host drops its side on cancel.
    func shutdown() {
        shutdownGeneration &+= 1
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
    onStatus: @escaping @Sendable (KeyboardBridgeStatus) async -> Void
) async throws {
    let helloData = try messageData(try await task.receive())
    let hello = try JSONDecoder().decode(KeyboardLocalBridgeHello.self, from: helloData)
    guard KeyboardLocalBridgeAuth.verifyServerHello(hello, bridgeToken: bridgeToken) else {
        throw URLError(.userAuthenticationRequired)
    }
    let payload = try JSONEncoder().encode(KeyboardLocalBridgeRequest.status(bridgeToken: bridgeToken))
    try await task.send(.data(payload))
    while !Task.isCancelled {
        let message = try await task.receive()
        let status = try JSONDecoder().decode(KeyboardBridgeStatus.self, from: try messageData(message))
        await onStatus(status)
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
        case .refineText:
            return 30
        }
    }
}
