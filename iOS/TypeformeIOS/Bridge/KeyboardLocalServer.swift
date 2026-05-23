import Foundation
import Network

final class KeyboardLocalServer {
    static let port: UInt16 = 18082
    private static let maxMessageBytes = 1 * 1024 * 1024

    var onCommand: ((KeyboardBridgeCommand) async -> KeyboardBridgeStatus)?
    var statusProvider: (() async -> KeyboardBridgeStatus)?
    var expectedTokenProvider: (() async -> String?)?

    private let queue = DispatchQueue(label: "com.typeforme.keyboard-server")
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
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
        guard !alreadyRunning else { return }

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
            if case .failed = state {
                self?.stop()
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        stateLock.lock()
        let currentListener = listener
        listener = nil
        generation += 1
        let connections = Array(activeConnections.values)
        activeConnections.removeAll()
        let tasks = Array(activeTasks.values)
        activeTasks.removeAll()
        stateLock.unlock()

        currentListener?.cancel()
        connections.forEach { $0.cancel() }
        tasks.forEach { $0.cancel() }
    }

    private func handle(_ connection: NWConnection, generation: UInt) {
        guard Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        stateLock.lock()
        guard generation == self.generation, listener != nil else {
            stateLock.unlock()
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
                    connection.cancel()
                    self.removeTask(taskID)
                    return
                }
                self.receiveMessage(from: connection, generation: generation, expectedToken: expectedToken)
                self.removeTask(taskID)
            }
        }
        storeTask(task, id: taskID, generation: generation)
    }

    private func receiveMessage(from connection: NWConnection, generation: UInt, expectedToken: String) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }

            guard error == nil,
                  let data,
                  data.count <= Self.maxMessageBytes
            else {
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
                let status = await self.status(for: request, expectedToken: expectedToken)
                guard !Task.isCancelled, self.isCurrentGeneration(generation) else {
                    connection.cancel()
                    self.removeTask(taskID)
                    return
                }
                self.send(status, connection: connection)
                self.removeTask(taskID)
            }
            self.storeTask(task, id: taskID, generation: generation)
        }
    }

    private func status(for request: KeyboardLocalBridgeRequest, expectedToken: String) async -> KeyboardBridgeStatus {
        guard isAuthorized(request, expectedToken: expectedToken) else {
            return KeyboardBridgeStatus(state: .error, message: "Keyboard bridge unauthorized")
        }
        switch request.action {
        case .status:
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
        completion: @escaping (Bool) -> Void
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

    private func send(_ status: KeyboardBridgeStatus, connection: NWConnection) {
        guard let data = try? JSONEncoder().encode(status) else {
            connection.cancel()
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "keyboard-bridge-status", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
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
        stateLock.unlock()
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
