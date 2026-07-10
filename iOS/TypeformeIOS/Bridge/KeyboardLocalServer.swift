import Foundation
import Network
import OSLog

private let keyboardLocalServerLog = Logger(
    subsystem: TypeformeBundleConfiguration.hostBundleIdentifier,
    category: "keyboard-local-server"
)

struct KeyboardLocalBridgeReadiness: Sendable {
    let ready: Bool
    let listenerState: String
    let generation: UInt
    let restarted: Bool
    let selfProbeSucceeded: Bool
    let failureReason: String?
    let elapsedMilliseconds: Int

    var diagnosticFields: [String: String] {
        [
            "ready": "\(ready)",
            "listener_state": listenerState,
            "generation": "\(generation)",
            "restarted": "\(restarted)",
            "self_probe_succeeded": "\(selfProbeSucceeded)",
            "failure_reason": failureReason ?? "none",
            "elapsed_ms": "\(elapsedMilliseconds)",
        ]
    }
}

final class KeyboardLocalServer: @unchecked Sendable {
    private enum SelfProbeOutcome {
        case succeeded
        case failed
        case cancelled
        case staleGeneration
    }

    private enum ListenerReadinessOutcome {
        case ready
        case timedOut
        case cancelled
        case staleGeneration
    }

    private enum RestartCondition {
        case listenerNotReady
        case selfProbeFailed
    }

    private struct ReadinessFlight {
        let id: UUID
        let initialGeneration: UInt
        let task: Task<KeyboardLocalBridgeReadiness, Never>
        var waiterIDs: Set<UUID>
    }

    static let port: UInt16 = 18082
    private static let maxMessageBytes = 1 * 1024 * 1024
    private static let maxTotalConnections = 16
    private static let maxUnauthenticatedConnections = 4
    private static let helloTimeoutNanoseconds: UInt64 = 1_500_000_000
    private static let requestReadTimeoutNanoseconds: UInt64 = 2_000_000_000
    private static let connectionIdleTimeoutNanoseconds: UInt64 = 8_000_000_000
    private static let refineHandlingTimeoutNanoseconds: UInt64 = 225_000_000_000
    private static let statusStreamHeartbeatIntervalNanoseconds: UInt64 = 2_000_000_000
    private static let readinessPollIntervalNanoseconds: UInt64 = 25_000_000
    private static let defaultReadinessTimeout: TimeInterval = 0.45
    private static let selfProbeTimeout: TimeInterval = 0.35

    var onCommand: ((KeyboardBridgeCommand) async -> KeyboardBridgeStatus)?
    var statusProvider: (() async -> KeyboardBridgeStatus)?
    var expectedTokenProvider: (() async -> String?)?

    private let queue = DispatchQueue(label: "\(TypeformeBundleConfiguration.hostBundleIdentifier).keyboard-server")
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var unauthenticatedConnections: Set<ObjectIdentifier> = []
    private var activeStatusStreams: [ObjectIdentifier: NWConnection] = [:]
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeTaskConnections: [UUID: ObjectIdentifier] = [:]
    private var connectionTimeouts: [ObjectIdentifier: (token: UUID, task: Task<Void, Never>)] = [:]
    private var statusStreamHeartbeatTask: Task<Void, Never>?
    private var generation: UInt = 0
    private var listenerStateDescription = "stopped"
    private var lastReadyAt: TimeInterval = 0
    private var lastAcceptedAt: TimeInterval = 0
    private var lastSelfProbeAt: TimeInterval = 0
    private var lastSelfProbeSucceeded = false
    private var readinessFlight: ReadinessFlight?

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listener != nil && listenerStateDescription == "ready"
    }

    func start() throws {
        stateLock.lock()
        let alreadyRunning = listener != nil
        let skippedFields = listenerDiagnosticFieldsLocked()
        stateLock.unlock()
        guard !alreadyRunning else {
            keyboardLocalServerLog.debug("server start skipped: already running state=\(skippedFields["listener_state"] ?? "unknown", privacy: .public) generation=\(skippedFields["generation"] ?? "0", privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "server_start_skipped_already_running",
                fields: skippedFields
            )
            return
        }

        let parameters = NWParameters.tcp
        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        webSocketOptions.maximumMessageSize = Self.maxMessageBytes
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
        stateLock.lock()
        if self.listener != nil {
            let skippedFields = listenerDiagnosticFieldsLocked()
            stateLock.unlock()
            listener.cancel()
            keyboardLocalServerLog.debug("server start skipped after listener creation: already running state=\(skippedFields["listener_state"] ?? "unknown", privacy: .public) generation=\(skippedFields["generation"] ?? "0", privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "server_start_skipped_already_running",
                fields: skippedFields
            )
            return
        }
        generation += 1
        let currentGeneration = generation
        self.listener = listener
        listenerStateDescription = "setup"
        lastReadyAt = 0
        lastAcceptedAt = 0
        lastSelfProbeAt = 0
        lastSelfProbeSucceeded = false
        stateLock.unlock()
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection, generation: currentGeneration)
        }
        listener.stateUpdateHandler = { [weak self] state in
            keyboardLocalServerLog.notice("listener state=\(String(describing: state), privacy: .public)")
            self?.recordListenerState(state, generation: currentGeneration)
            if case .failed(let error) = state {
                // Keep the failed listener attached to its generation. The next
                // readiness flight can then replace exactly that generation;
                // clearing it here would erase ownership and let a stale flight
                // race a newly healthy listener.
                KeyboardDiagnosticEventLog.record(
                    source: "host-local-server",
                    event: "listener_failed_awaiting_conditional_restart",
                    fields: [
                        "generation": "\(currentGeneration)",
                        "error": error.localizedDescription,
                    ]
                )
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

    func stop(reason: String = "explicit") {
        stop(reason: reason, onlyGeneration: nil, restartCondition: nil)
    }

    @discardableResult
    private func stop(
        reason: String,
        onlyGeneration expectedGeneration: UInt?,
        restartCondition: RestartCondition?
    ) -> Bool {
        stateLock.lock()
        if let expectedGeneration,
           generation != expectedGeneration || listener == nil {
            let fields = listenerDiagnosticFieldsLocked().merging([
                "reason": reason,
                "expected_generation": "\(expectedGeneration)",
                "skipped": "true",
            ]) { current, _ in current }
            stateLock.unlock()
            keyboardLocalServerLog.debug("server stop skipped reason=\(reason, privacy: .public) expected_generation=\(expectedGeneration, privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "server_stop_skipped_stale_generation",
                fields: fields
            )
            return false
        }
        if case .listenerNotReady? = restartCondition,
           listenerStateDescription == "ready" {
            let fields = listenerDiagnosticFieldsLocked().merging([
                "reason": reason,
                "expected_generation": "\(expectedGeneration ?? generation)",
                "skipped": "true",
                "skip_reason": "listener_became_ready",
            ]) { current, _ in current }
            stateLock.unlock()
            keyboardLocalServerLog.debug("server stop skipped: listener became ready reason=\(reason, privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "server_stop_skipped_listener_became_ready",
                fields: fields
            )
            return false
        }
        let currentListener = listener
        listener = nil
        generation += 1
        listenerStateDescription = "stopped"
        let connections = Array(activeConnections.values)
        activeConnections.removeAll()
        unauthenticatedConnections.removeAll()
        activeStatusStreams.removeAll()
        let tasks = Array(activeTasks.values)
        activeTasks.removeAll()
        activeTaskConnections.removeAll()
        let timeoutTasks = connectionTimeouts.values.map(\.task)
        connectionTimeouts.removeAll()
        let heartbeatTask = statusStreamHeartbeatTask
        statusStreamHeartbeatTask = nil
        stateLock.unlock()

        currentListener?.cancel()
        connections.forEach { $0.cancel() }
        tasks.forEach { $0.cancel() }
        timeoutTasks.forEach { $0.cancel() }
        heartbeatTask?.cancel()
        keyboardLocalServerLog.notice("server stopped reason=\(reason, privacy: .public) connections=\(connections.count, privacy: .public) tasks=\(tasks.count, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-local-server",
            event: "server_stopped",
            fields: [
                "reason": reason,
                "connections": "\(connections.count)",
                "tasks": "\(tasks.count)",
            ]
        )
        return true
    }

    func ensureReady(
        reason: String,
        timeout: TimeInterval = KeyboardLocalServer.defaultReadinessTimeout,
        forceProbe: Bool = false
    ) async -> KeyboardLocalBridgeReadiness {
        let startedAt = Date().timeIntervalSince1970
        KeyboardDiagnosticEventLog.record(
            source: "host-local-server",
            event: "bridge_ensure_begin",
            fields: listenerDiagnosticFields(reason: reason)
        )

        guard !Task.isCancelled else {
            return finishEnsureReady(
                reason: reason,
                startedAt: startedAt,
                restarted: false,
                selfProbeSucceeded: false,
                failureReason: "cancelled",
                cancelled: true,
                forceProbe: forceProbe,
                ownedGeneration: nil,
                additionalDiagnosticFields: ["singleflight": "not_started"]
            )
        }

        do {
            if !hasListener {
                try start()
            }
        } catch {
            return finishEnsureReady(
                reason: reason,
                startedAt: startedAt,
                restarted: false,
                selfProbeSucceeded: false,
                failureReason: Self.isCancellation(error) ? "cancelled" : error.localizedDescription,
                cancelled: Self.isCancellation(error),
                forceProbe: forceProbe,
                ownedGeneration: nil,
                additionalDiagnosticFields: ["singleflight": "start_failed"]
            )
        }

        guard !Task.isCancelled else {
            return finishEnsureReady(
                reason: reason,
                startedAt: startedAt,
                restarted: false,
                selfProbeSucceeded: false,
                failureReason: "cancelled",
                cancelled: true,
                forceProbe: forceProbe,
                ownedGeneration: nil,
                additionalDiagnosticFields: ["singleflight": "not_started"]
            )
        }

        let waiterID = UUID()
        let flight = acquireReadinessFlight(
            waiterID: waiterID,
            reason: reason,
            timeout: timeout,
            forceProbe: forceProbe
        )
        let singleflightFields = [
            "reason": reason,
            "flight_id": flight.id.uuidString,
            "flight_generation": "\(flight.initialGeneration)",
            "joined": "\(flight.joined)",
        ]
        KeyboardDiagnosticEventLog.record(
            source: "host-local-server",
            event: flight.joined ? "bridge_ensure_singleflight_joined" : "bridge_ensure_singleflight_started",
            fields: singleflightFields
        )

        // Readiness owns process infrastructure, not a recording command. A
        // caller cancellation must not cancel/restart the listener underneath
        // the immediately following command; the short shared flight finishes.
        let sharedResult = await flight.task.value
        completeReadinessWaiter(flightID: flight.id, waiterID: waiterID)

        let result = KeyboardLocalBridgeReadiness(
            ready: sharedResult.ready,
            listenerState: sharedResult.listenerState,
            generation: sharedResult.generation,
            restarted: sharedResult.restarted,
            selfProbeSucceeded: sharedResult.selfProbeSucceeded,
            failureReason: sharedResult.failureReason,
            elapsedMilliseconds: Int((Date().timeIntervalSince1970 - startedAt) * 1_000)
        )
        KeyboardDiagnosticEventLog.record(
            source: "host-local-server",
            event: "bridge_ensure_result",
            fields: result.diagnosticFields.merging(singleflightFields) { current, _ in current }
        )
        keyboardLocalServerLog.notice("bridge ensure result reason=\(reason, privacy: .public) ready=\(result.ready, privacy: .public) state=\(result.listenerState, privacy: .public) generation=\(result.generation, privacy: .public) restarted=\(result.restarted, privacy: .public) probe=\(result.selfProbeSucceeded, privacy: .public) elapsed_ms=\(result.elapsedMilliseconds, privacy: .public)")
        return result
    }

    private func performEnsureReady(
        reason: String,
        timeout: TimeInterval,
        forceProbe: Bool,
        initialGeneration: UInt
    ) async -> KeyboardLocalBridgeReadiness {
        let startedAt = Date().timeIntervalSince1970
        var ownedGeneration = initialGeneration
        var restarted = false
        var failureReason: String?
        var selfProbeSucceeded = false
        var readinessCheckCancelled = false

        do {
            switch await waitUntilListenerReady(timeout: timeout, generation: ownedGeneration) {
            case .ready:
                break
            case .cancelled:
                readinessCheckCancelled = true
                failureReason = "cancelled"
            case .staleGeneration:
                failureReason = "stale_generation"
            case .timedOut:
                failureReason = "listener_not_ready"
                guard !Task.isCancelled else {
                    readinessCheckCancelled = true
                    failureReason = "cancelled"
                    break
                }
                if let replacementGeneration = try forceRestart(
                    reason: "\(reason):listener_not_ready",
                    expectedGeneration: ownedGeneration,
                    condition: .listenerNotReady
                ) {
                    restarted = true
                    ownedGeneration = replacementGeneration
                    switch await waitUntilListenerReady(timeout: timeout, generation: ownedGeneration) {
                    case .ready:
                        break
                    case .cancelled:
                        readinessCheckCancelled = true
                        failureReason = "cancelled"
                    case .staleGeneration:
                        failureReason = "stale_generation"
                    case .timedOut:
                        failureReason = "listener_not_ready_after_restart"
                    }
                }
            }

            let listenerSnapshot = listenerDiagnosticSnapshot()
            if !readinessCheckCancelled,
               listenerSnapshot.generation == ownedGeneration,
               listenerSnapshot.isReady {
                if forceProbe || shouldSelfProbeForReadiness(generation: ownedGeneration) {
                    switch await selfProbe(reason: reason, generation: ownedGeneration) {
                    case .succeeded:
                        selfProbeSucceeded = true
                    case .cancelled:
                        readinessCheckCancelled = true
                        failureReason = "cancelled"
                    case .staleGeneration:
                        failureReason = "stale_generation"
                    case .failed:
                        failureReason = "self_probe_failed"
                        guard !Task.isCancelled else {
                            readinessCheckCancelled = true
                            failureReason = "cancelled"
                            break
                        }
                        if let replacementGeneration = try forceRestart(
                            reason: "\(reason):self_probe_failed",
                            expectedGeneration: ownedGeneration,
                            condition: .selfProbeFailed
                        ) {
                            restarted = true
                            ownedGeneration = replacementGeneration
                            if case .ready = await waitUntilListenerReady(
                                timeout: timeout,
                                generation: ownedGeneration
                            ) {
                                switch await selfProbe(
                                    reason: "\(reason):after_restart",
                                    generation: ownedGeneration
                                ) {
                                case .succeeded:
                                    selfProbeSucceeded = true
                                case .cancelled:
                                    readinessCheckCancelled = true
                                    failureReason = "cancelled"
                                case .staleGeneration:
                                    failureReason = "stale_generation"
                                case .failed:
                                    failureReason = "self_probe_failed_after_restart"
                                }
                            } else if Task.isCancelled {
                                readinessCheckCancelled = true
                                failureReason = "cancelled"
                            } else {
                                failureReason = "listener_not_ready_after_restart"
                            }
                        }
                    }
                } else {
                    selfProbeSucceeded = listenerSnapshot.lastSelfProbeSucceeded
                }
            }
        } catch {
            let cancelled = Task.isCancelled || Self.isCancellation(error)
            readinessCheckCancelled = cancelled
            failureReason = cancelled ? "cancelled" : error.localizedDescription
        }

        return finishEnsureReady(
            reason: reason,
            startedAt: startedAt,
            restarted: restarted,
            selfProbeSucceeded: selfProbeSucceeded,
            failureReason: failureReason,
            cancelled: readinessCheckCancelled,
            forceProbe: forceProbe,
            ownedGeneration: ownedGeneration,
            additionalDiagnosticFields: ["singleflight": "operation"]
        )
    }

    private func finishEnsureReady(
        reason: String,
        startedAt: TimeInterval,
        restarted: Bool,
        selfProbeSucceeded: Bool,
        failureReason: String?,
        cancelled: Bool,
        forceProbe: Bool,
        ownedGeneration: UInt?,
        additionalDiagnosticFields: [String: String]
    ) -> KeyboardLocalBridgeReadiness {
        let snapshot = listenerDiagnosticSnapshot()
        // Cancellation is not evidence that a ready shared listener is broken.
        // A stale non-cancelled flight, however, must not certify a replacement
        // generation it never checked.
        let ownsSnapshot = ownedGeneration == nil || ownedGeneration == snapshot.generation
        let ready = snapshot.isReady
            && (cancelled || (ownsSnapshot && (!forceProbe || selfProbeSucceeded)))
        let result = KeyboardLocalBridgeReadiness(
            ready: ready,
            listenerState: snapshot.listenerState,
            generation: snapshot.generation,
            restarted: restarted,
            selfProbeSucceeded: selfProbeSucceeded,
            failureReason: ready ? nil : failureReason,
            elapsedMilliseconds: Int((Date().timeIntervalSince1970 - startedAt) * 1_000)
        )
        KeyboardDiagnosticEventLog.record(
            source: "host-local-server",
            event: "bridge_ensure_operation_result",
            fields: result.diagnosticFields.merging(
                additionalDiagnosticFields.merging(["reason": reason]) { current, _ in current }
            ) { current, _ in current }
        )
        return result
    }

    private func acquireReadinessFlight(
        waiterID: UUID,
        reason: String,
        timeout: TimeInterval,
        forceProbe: Bool
    ) -> (
        id: UUID,
        initialGeneration: UInt,
        task: Task<KeyboardLocalBridgeReadiness, Never>,
        joined: Bool
    ) {
        stateLock.lock()
        if var flight = readinessFlight {
            flight.waiterIDs.insert(waiterID)
            readinessFlight = flight
            stateLock.unlock()
            return (flight.id, flight.initialGeneration, flight.task, true)
        }

        let flightID = UUID()
        let initialGeneration = generation
        let task = Task { [self] in
            let result = await performEnsureReady(
                reason: reason,
                timeout: timeout,
                forceProbe: forceProbe,
                initialGeneration: initialGeneration
            )
            completeReadinessFlightOperation(flightID: flightID)
            return result
        }
        readinessFlight = ReadinessFlight(
            id: flightID,
            initialGeneration: initialGeneration,
            task: task,
            waiterIDs: [waiterID]
        )
        stateLock.unlock()
        return (flightID, initialGeneration, task, false)
    }

    private func completeReadinessFlightOperation(flightID: UUID) {
        stateLock.lock()
        if readinessFlight?.id == flightID {
            readinessFlight = nil
        }
        stateLock.unlock()
    }

    private func completeReadinessWaiter(flightID: UUID, waiterID: UUID) {
        stateLock.lock()
        guard var flight = readinessFlight, flight.id == flightID else {
            stateLock.unlock()
            return
        }
        flight.waiterIDs.remove(waiterID)
        if flight.waiterIDs.isEmpty {
            readinessFlight = nil
        } else {
            readinessFlight = flight
        }
        stateLock.unlock()
    }

    private func forceRestart(
        reason: String,
        expectedGeneration: UInt,
        condition: RestartCondition
    ) throws -> UInt? {
        guard !Task.isCancelled else { throw CancellationError() }
        KeyboardDiagnosticEventLog.record(
            source: "host-local-server",
            event: "listener_force_restart_begin",
            fields: listenerDiagnosticFields(reason: reason).merging([
                "expected_generation": "\(expectedGeneration)",
            ]) { current, _ in current }
        )
        keyboardLocalServerLog.notice("listener conditional restart begin reason=\(reason, privacy: .public) expected_generation=\(expectedGeneration, privacy: .public)")
        guard stop(
            reason: "force_restart:\(reason)",
            onlyGeneration: expectedGeneration,
            restartCondition: condition
        ) else {
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "listener_force_restart_skipped",
                fields: listenerDiagnosticFields(reason: reason).merging([
                    "expected_generation": "\(expectedGeneration)",
                ]) { current, _ in current }
            )
            return nil
        }
        // Once this operation detached the old listener, complete the restart
        // transaction even if its last waiter was cancelled. Leaving a nil
        // listener would poison the immediately following recording round.
        try start()
        let replacement = listenerDiagnosticSnapshot()
        KeyboardDiagnosticEventLog.record(
            source: "host-local-server",
            event: "listener_force_restart_end",
            fields: listenerDiagnosticFields(reason: reason).merging([
                "expected_generation": "\(expectedGeneration)",
                "replacement_generation": "\(replacement.generation)",
            ]) { current, _ in current }
        )
        return replacement.hasListener ? replacement.generation : nil
    }

    private var hasListener: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listener != nil
    }

    private func waitUntilListenerReady(
        timeout: TimeInterval,
        generation expectedGeneration: UInt
    ) async -> ListenerReadinessOutcome {
        let deadline = Date().timeIntervalSince1970 + max(timeout, 0)
        while Date().timeIntervalSince1970 < deadline {
            guard !Task.isCancelled else { return .cancelled }
            let snapshot = listenerDiagnosticSnapshot()
            guard snapshot.generation == expectedGeneration, snapshot.hasListener else {
                return .staleGeneration
            }
            if snapshot.isReady { return .ready }
            do {
                try await Task.sleep(nanoseconds: Self.readinessPollIntervalNanoseconds)
            } catch {
                return .cancelled
            }
        }
        guard !Task.isCancelled else { return .cancelled }
        let snapshot = listenerDiagnosticSnapshot()
        guard snapshot.generation == expectedGeneration, snapshot.hasListener else {
            return .staleGeneration
        }
        return snapshot.isReady ? .ready : .timedOut
    }

    private func shouldSelfProbeForReadiness(
        generation expectedGeneration: UInt,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == expectedGeneration,
              listener != nil,
              listenerStateDescription == "ready"
        else { return false }
        guard lastSelfProbeSucceeded else { return true }
        return now - lastSelfProbeAt > 30
    }

    private func recordListenerState(_ state: NWListener.State, generation currentGeneration: UInt) {
        let now = Date().timeIntervalSince1970
        let description = Self.listenerStateDescription(for: state)
        var fields: [String: String] = [:]
        stateLock.lock()
        if currentGeneration == generation, listener != nil {
            listenerStateDescription = description
            if case .ready = state {
                lastReadyAt = now
            }
            fields = listenerDiagnosticFieldsLocked(now: now)
        } else {
            fields = [
                "generation": "\(currentGeneration)",
                "current_generation": "\(generation)",
                "listener_state": description,
                "stale": "true",
            ]
        }
        stateLock.unlock()
        KeyboardDiagnosticEventLog.record(
            source: "host-local-server",
            event: "listener_state_changed",
            fields: fields
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
        let acceptedAt = Date().timeIntervalSince1970
        keyboardLocalServerLog.notice("connection accepted endpoint=\(String(describing: connection.endpoint), privacy: .public) generation=\(generation, privacy: .public)")
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
        guard activeConnections.count < Self.maxTotalConnections else {
            let count = activeConnections.count
            stateLock.unlock()
            keyboardLocalServerLog.notice("connection rejected: total limit count=\(count, privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "connection_rejected_total_limit",
                fields: ["active_connections": "\(count)"]
            )
            connection.cancel()
            return
        }
        guard unauthenticatedConnections.count < Self.maxUnauthenticatedConnections else {
            let count = unauthenticatedConnections.count
            stateLock.unlock()
            keyboardLocalServerLog.notice("connection rejected: unauthenticated limit count=\(count, privacy: .public)")
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "connection_rejected_unauthenticated_limit",
                fields: ["unauthenticated_connections": "\(count)"]
            )
            connection.cancel()
            return
        }
        activeConnections[id] = connection
        unauthenticatedConnections.insert(id)
        lastAcceptedAt = acceptedAt
        let diagnosticFields = listenerDiagnosticFieldsLocked(now: acceptedAt)
        stateLock.unlock()
        KeyboardDiagnosticEventLog.record(
            source: "host-local-server",
            event: "connection_accepted",
            fields: diagnosticFields.merging([
                "endpoint": String(describing: connection.endpoint),
                "generation": "\(generation)",
            ]) { current, _ in current }
        )
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.removeConnection(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        scheduleConnectionTimeout(
            id,
            generation: generation,
            after: Self.helloTimeoutNanoseconds,
            reason: "hello"
        )
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
                self.scheduleConnectionTimeout(
                    ObjectIdentifier(connection),
                    generation: generation,
                    after: Self.requestReadTimeoutNanoseconds,
                    reason: "request_read"
                )
                self.receiveMessage(
                    from: connection,
                    generation: generation,
                    expectedToken: expectedToken,
                    serverNonce: hello.nonce
                )
                self.removeTask(taskID)
            }
        }
        storeTask(
            task,
            id: taskID,
            generation: generation,
            connectionID: ObjectIdentifier(connection)
        )
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

    private func receiveMessage(
        from connection: NWConnection,
        generation: UInt,
        expectedToken: String,
        serverNonce: String
    ) {
        let connectionID = ObjectIdentifier(connection)
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            self.cancelConnectionTimeout(connectionID)

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
            self.scheduleConnectionTimeout(
                connectionID,
                generation: generation,
                after: Self.connectionIdleTimeoutNanoseconds,
                reason: "request_handling"
            )
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
            if request.command?.action == .refineText {
                // Refinement may include cold model startup, format repair,
                // and verification. Do not let the localhost connection cancel
                // its command owner before the paired bridge reaches terminal.
                self.scheduleConnectionTimeout(
                    connectionID,
                    generation: generation,
                    after: Self.refineHandlingTimeoutNanoseconds,
                    reason: "refine_handling"
                )
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
                let authorized = self.isAuthorized(
                    request,
                    expectedToken: expectedToken,
                    serverNonce: serverNonce
                )
                if authorized {
                    guard self.markConnectionAuthenticated(connectionID, generation: generation) else {
                        connection.cancel()
                        self.removeTask(taskID)
                        return
                    }
                }
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
            self.storeTask(
                task,
                id: taskID,
                generation: generation,
                connectionID: connectionID
            )
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

    private func isAuthorized(
        _ request: KeyboardLocalBridgeRequest,
        expectedToken: String,
        serverNonce: String
    ) -> Bool {
        request.hasValidAuthentication(
            bridgeToken: expectedToken,
            serverNonce: serverNonce
        )
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
        cancelConnectionTimeout(id)
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

    private func storeTask(
        _ task: Task<Void, Never>,
        id: UUID,
        generation: UInt,
        connectionID: ObjectIdentifier
    ) {
        stateLock.lock()
        if generation == self.generation,
           listener != nil,
           activeConnections[connectionID] != nil {
            activeTasks[id] = task
            activeTaskConnections[id] = connectionID
        } else {
            task.cancel()
        }
        stateLock.unlock()
    }

    private func removeTask(_ id: UUID) {
        stateLock.lock()
        activeTasks[id] = nil
        activeTaskConnections[id] = nil
        stateLock.unlock()
    }

    private func removeConnection(_ id: ObjectIdentifier) {
        stateLock.lock()
        activeConnections[id] = nil
        unauthenticatedConnections.remove(id)
        activeStatusStreams[id] = nil
        let connectionTaskIDs = activeTaskConnections.compactMap { taskID, connectionID in
            connectionID == id ? taskID : nil
        }
        let connectionTasks = connectionTaskIDs.compactMap { activeTasks.removeValue(forKey: $0) }
        connectionTaskIDs.forEach { activeTaskConnections[$0] = nil }
        let timeoutTask = connectionTimeouts.removeValue(forKey: id)?.task
        let heartbeatTask: Task<Void, Never>?
        if activeStatusStreams.isEmpty {
            heartbeatTask = statusStreamHeartbeatTask
            statusStreamHeartbeatTask = nil
        } else {
            heartbeatTask = nil
        }
        stateLock.unlock()
        connectionTasks.forEach { $0.cancel() }
        timeoutTask?.cancel()
        heartbeatTask?.cancel()
    }

    private func markConnectionAuthenticated(_ id: ObjectIdentifier, generation: UInt) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == self.generation,
              listener != nil,
              activeConnections[id] != nil
        else { return false }
        unauthenticatedConnections.remove(id)
        return true
    }

    private func scheduleConnectionTimeout(
        _ id: ObjectIdentifier,
        generation: UInt,
        after nanoseconds: UInt64,
        reason: String
    ) {
        let token = UUID()
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            self?.expireConnection(id, generation: generation, token: token, reason: reason)
        }

        stateLock.lock()
        guard generation == self.generation,
              listener != nil,
              activeConnections[id] != nil
        else {
            stateLock.unlock()
            task.cancel()
            return
        }
        let previous = connectionTimeouts.updateValue((token: token, task: task), forKey: id)?.task
        stateLock.unlock()
        previous?.cancel()
    }

    private func cancelConnectionTimeout(_ id: ObjectIdentifier) {
        stateLock.lock()
        let task = connectionTimeouts.removeValue(forKey: id)?.task
        stateLock.unlock()
        task?.cancel()
    }

    private func expireConnection(
        _ id: ObjectIdentifier,
        generation: UInt,
        token: UUID,
        reason: String
    ) {
        stateLock.lock()
        guard generation == self.generation,
              connectionTimeouts[id]?.token == token,
              let connection = activeConnections[id]
        else {
            stateLock.unlock()
            return
        }
        connectionTimeouts[id] = nil
        stateLock.unlock()

        keyboardLocalServerLog.notice("connection timed out phase=\(reason, privacy: .public)")
        KeyboardDiagnosticEventLog.record(
            source: "host-local-server",
            event: "connection_timed_out",
            fields: ["phase": reason]
        )
        connection.cancel()
        removeConnection(id)
    }

    private func isCurrentGeneration(_ generation: UInt) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == self.generation && listener != nil
    }

    private struct ListenerDiagnosticSnapshot {
        let hasListener: Bool
        let isReady: Bool
        let listenerState: String
        let generation: UInt
        let lastReadyAgeMS: Int
        let lastAcceptedAgeMS: Int
        let lastSelfProbeAgeMS: Int
        let lastSelfProbeSucceeded: Bool
    }

    private func listenerDiagnosticSnapshot(now: TimeInterval = Date().timeIntervalSince1970) -> ListenerDiagnosticSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listenerDiagnosticSnapshotLocked(now: now)
    }

    private func listenerDiagnosticSnapshotLocked(now: TimeInterval = Date().timeIntervalSince1970) -> ListenerDiagnosticSnapshot {
        ListenerDiagnosticSnapshot(
            hasListener: listener != nil,
            isReady: listener != nil && listenerStateDescription == "ready",
            listenerState: listenerStateDescription,
            generation: generation,
            lastReadyAgeMS: Self.ageMilliseconds(since: lastReadyAt, now: now),
            lastAcceptedAgeMS: Self.ageMilliseconds(since: lastAcceptedAt, now: now),
            lastSelfProbeAgeMS: Self.ageMilliseconds(since: lastSelfProbeAt, now: now),
            lastSelfProbeSucceeded: lastSelfProbeSucceeded
        )
    }

    private func listenerDiagnosticFields(
        reason: String? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [String: String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listenerDiagnosticFieldsLocked(reason: reason, now: now)
    }

    private func listenerDiagnosticFieldsLocked(
        reason: String? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [String: String] {
        let snapshot = listenerDiagnosticSnapshotLocked(now: now)
        var fields: [String: String] = [
            "has_listener": "\(snapshot.hasListener)",
            "is_ready": "\(snapshot.isReady)",
            "listener_state": snapshot.listenerState,
            "generation": "\(snapshot.generation)",
            "last_ready_age_ms": "\(snapshot.lastReadyAgeMS)",
            "last_accept_age_ms": "\(snapshot.lastAcceptedAgeMS)",
            "last_self_probe_age_ms": "\(snapshot.lastSelfProbeAgeMS)",
            "last_self_probe_succeeded": "\(snapshot.lastSelfProbeSucceeded)",
        ]
        if let reason {
            fields["reason"] = reason
        }
        return fields
    }

    private func selfProbe(reason: String, generation expectedGeneration: UInt) async -> SelfProbeOutcome {
        let startedAt = Date().timeIntervalSince1970
        KeyboardDiagnosticEventLog.record(
            source: "host-local-server",
            event: "self_probe_begin",
            fields: listenerDiagnosticFields(reason: reason, now: startedAt).merging([
                "expected_generation": "\(expectedGeneration)",
            ]) { current, _ in current }
        )
        guard !Task.isCancelled else {
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "self_probe_cancelled",
                fields: ["reason": reason, "elapsed_ms": "0"]
            )
            return .cancelled
        }
        guard isCurrentGeneration(expectedGeneration) else {
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "self_probe_stale_generation",
                fields: [
                    "reason": reason,
                    "expected_generation": "\(expectedGeneration)",
                    "elapsed_ms": "0",
                ]
            )
            return .staleGeneration
        }
        guard let expectedToken = await expectedTokenProvider?(),
              !expectedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            if Task.isCancelled {
                KeyboardDiagnosticEventLog.record(
                    source: "host-local-server",
                    event: "self_probe_cancelled",
                    fields: [
                        "reason": reason,
                        "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startedAt) * 1_000))",
                    ]
                )
                return .cancelled
            }
            guard updateSelfProbeResult(false, generation: expectedGeneration) else {
                KeyboardDiagnosticEventLog.record(
                    source: "host-local-server",
                    event: "self_probe_stale_generation",
                    fields: [
                        "reason": reason,
                        "expected_generation": "\(expectedGeneration)",
                        "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startedAt) * 1_000))",
                    ]
                )
                return .staleGeneration
            }
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "self_probe_failure",
                fields: [
                    "reason": reason,
                    "error": "missing_token",
                    "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startedAt) * 1_000))",
                ]
            )
            return .failed
        }
        guard !Task.isCancelled else {
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "self_probe_cancelled",
                fields: [
                    "reason": reason,
                    "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startedAt) * 1_000))",
                ]
            )
            return .cancelled
        }
        guard isCurrentGeneration(expectedGeneration) else {
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "self_probe_stale_generation",
                fields: [
                    "reason": reason,
                    "expected_generation": "\(expectedGeneration)",
                    "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startedAt) * 1_000))",
                ]
            )
            return .staleGeneration
        }

        let session = URLSession(configuration: .ephemeral)
        var urlRequest = URLRequest(url: URL(string: "ws://127.0.0.1:\(Self.port)/keyboard")!)
        urlRequest.timeoutInterval = Self.selfProbeTimeout
        let task = session.webSocketTask(with: urlRequest)
        task.maximumMessageSize = Self.maxMessageBytes
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        do {
            let helloData = try Self.messageData(try await Self.receiveMessage(on: task, timeout: Self.selfProbeTimeout))
            let hello = try JSONDecoder().decode(KeyboardLocalBridgeHello.self, from: helloData)
            guard KeyboardLocalBridgeAuth.verifyServerHello(hello, bridgeToken: expectedToken) else {
                throw URLError(.userAuthenticationRequired)
            }
            guard let request = KeyboardLocalBridgeRequest.statusSnapshot().authenticated(
                bridgeToken: expectedToken,
                serverNonce: hello.nonce
            ) else {
                throw URLError(.userAuthenticationRequired)
            }
            try await task.send(.data(try JSONEncoder().encode(request)))
            _ = try JSONDecoder().decode(
                KeyboardBridgeStatus.self,
                from: try Self.messageData(try await Self.receiveMessage(on: task, timeout: Self.selfProbeTimeout))
            )
            guard !Task.isCancelled else { throw CancellationError() }
            guard updateSelfProbeResult(true, generation: expectedGeneration) else {
                KeyboardDiagnosticEventLog.record(
                    source: "host-local-server",
                    event: "self_probe_stale_generation",
                    fields: [
                        "reason": reason,
                        "expected_generation": "\(expectedGeneration)",
                        "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startedAt) * 1_000))",
                    ]
                )
                return .staleGeneration
            }
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "self_probe_success",
                fields: [
                    "reason": reason,
                    "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startedAt) * 1_000))",
                ]
            )
            return .succeeded
        } catch {
            if Task.isCancelled || Self.isCancellation(error) {
                KeyboardDiagnosticEventLog.record(
                    source: "host-local-server",
                    event: "self_probe_cancelled",
                    fields: [
                        "reason": reason,
                        "error": error.localizedDescription,
                        "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startedAt) * 1_000))",
                    ]
                )
                return .cancelled
            }
            guard updateSelfProbeResult(false, generation: expectedGeneration) else {
                KeyboardDiagnosticEventLog.record(
                    source: "host-local-server",
                    event: "self_probe_stale_generation",
                    fields: [
                        "reason": reason,
                        "expected_generation": "\(expectedGeneration)",
                        "error": error.localizedDescription,
                        "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startedAt) * 1_000))",
                    ]
                )
                return .staleGeneration
            }
            KeyboardDiagnosticEventLog.record(
                source: "host-local-server",
                event: "self_probe_failure",
                fields: [
                    "reason": reason,
                    "error": error.localizedDescription,
                    "elapsed_ms": "\(Int((Date().timeIntervalSince1970 - startedAt) * 1_000))",
                ]
            )
            return .failed
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        isCancellation(error, depth: 0)
    }

    private static func isCancellation(_ error: Error, depth: Int) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled { return true }
        if let posixError = error as? POSIXError, posixError.code == .ECANCELED { return true }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == URLError.Code.cancelled.rawValue {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.Code.userCancelled.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == POSIXError.Code.ECANCELED.rawValue {
            return true
        }
        if nsError.domain == "Swift.CancellationError" {
            return true
        }

        if depth < 4,
           let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           (underlyingError as NSError) !== nsError {
            return isCancellation(underlyingError, depth: depth + 1)
        }
        return false
    }

    @discardableResult
    private func updateSelfProbeResult(_ succeeded: Bool, generation expectedGeneration: UInt) -> Bool {
        stateLock.lock()
        guard generation == expectedGeneration,
              listener != nil,
              listenerStateDescription == "ready"
        else {
            stateLock.unlock()
            return false
        }
        lastSelfProbeAt = Date().timeIntervalSince1970
        lastSelfProbeSucceeded = succeeded
        stateLock.unlock()
        return true
    }

    private static func listenerStateDescription(for state: NWListener.State) -> String {
        switch state {
        case .setup:
            return "setup"
        case .waiting(_):
            return "waiting"
        case .ready:
            return "ready"
        case .failed(_):
            return "failed"
        case .cancelled:
            return "cancelled"
        @unknown default:
            return "unknown"
        }
    }

    private static func ageMilliseconds(since timestamp: TimeInterval, now: TimeInterval) -> Int {
        guard timestamp > 0, now >= timestamp else { return -1 }
        return Int((now - timestamp) * 1_000)
    }

    private static func receiveMessage(
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

    private static func messageData(_ message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case .data(let responseData):
            return responseData
        case .string(let responseString):
            return Data(responseString.utf8)
        @unknown default:
            throw URLError(.cannotDecodeContentData)
        }
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
