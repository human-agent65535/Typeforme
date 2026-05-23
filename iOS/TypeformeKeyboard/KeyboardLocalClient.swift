import Foundation

struct KeyboardLocalClient {
    private let url = URL(string: "ws://127.0.0.1:18082/keyboard")!
    private let session: URLSession

    init() {
        self.session = URLSession(configuration: .ephemeral)
    }

    func status(bridgeToken: String?, timeout: TimeInterval = 0.45) async throws -> KeyboardBridgeStatus {
        try await send(action: .status, command: nil, bridgeToken: bridgeToken, timeout: timeout)
    }

    func send(_ command: KeyboardBridgeCommand, bridgeToken: String?, timeout: TimeInterval) async throws -> KeyboardBridgeStatus {
        try await send(action: .command, command: command, bridgeToken: bridgeToken, timeout: timeout)
    }

    private func send(
        action: KeyboardLocalBridgeRequest.Action,
        command: KeyboardBridgeCommand?,
        bridgeToken: String?,
        timeout: TimeInterval
    ) async throws -> KeyboardBridgeStatus {
        guard let bridgeToken,
              !bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw URLError(.userAuthenticationRequired)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = timeout
        let task = session.webSocketTask(with: urlRequest)
        task.maximumMessageSize = 1 * 1024 * 1024
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
        }

        return try await withThrowingTaskGroup(of: KeyboardBridgeStatus.self) { group in
            group.addTask {
                let helloMessage = try await task.receive()
                let helloData = try messageData(helloMessage)
                let hello = try JSONDecoder().decode(KeyboardLocalBridgeHello.self, from: helloData)
                guard KeyboardLocalBridgeAuth.verifyServerHello(hello, bridgeToken: bridgeToken) else {
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
                let payload = try JSONEncoder().encode(request)
                try await task.send(.data(payload))
                let message = try await task.receive()
                let data = try messageData(message)
                return try JSONDecoder().decode(KeyboardBridgeStatus.self, from: data)
            }
            group.addTask {
                let seconds = max(timeout, 0.05)
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }

            guard let result = try await group.next() else {
                throw URLError(.unknown)
            }
            group.cancelAll()
            return result
        }
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
            return 90
        case .restyleText:
            return 30
        }
    }
}
