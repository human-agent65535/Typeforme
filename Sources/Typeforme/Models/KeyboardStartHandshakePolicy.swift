struct KeyboardStartHandshakePolicy {
    enum StatusState: Equatable {
        case idle
        case standby
        case recording
        case sending
        case result
        case error
    }

    struct Snapshot: Equatable {
        var isStartRequestInFlight: Bool
        var pendingStartCommandID: String?
        var activeRecordingCommandID: String?
        var pendingDarwinStartAckCommandID: String?
        var trackedStartCommandIDs: Set<String>

        init(
            isStartRequestInFlight: Bool,
            pendingStartCommandID: String?,
            activeRecordingCommandID: String?,
            pendingDarwinStartAckCommandID: String?,
            trackedStartCommandIDs: Set<String>
        ) {
            self.isStartRequestInFlight = isStartRequestInFlight
            self.pendingStartCommandID = pendingStartCommandID
            self.activeRecordingCommandID = activeRecordingCommandID
            self.pendingDarwinStartAckCommandID = pendingDarwinStartAckCommandID
            self.trackedStartCommandIDs = trackedStartCommandIDs
        }
    }

    static func isTrackedStartCommandID(_ commandID: String, in snapshot: Snapshot) -> Bool {
        commandID == snapshot.pendingStartCommandID
            || commandID == snapshot.activeRecordingCommandID
            || commandID == snapshot.pendingDarwinStartAckCommandID
            || snapshot.trackedStartCommandIDs.contains(commandID)
    }

    static func shouldIgnoreStatusDuringStart(
        state: StatusState,
        commandID: String?,
        snapshot: Snapshot
    ) -> Bool {
        guard snapshot.isStartRequestInFlight || snapshot.pendingStartCommandID != nil else {
            return false
        }

        switch state {
        case .idle, .standby:
            return true
        case .recording, .sending, .result, .error:
            guard let commandID else { return true }
            return !isTrackedStartCommandID(commandID, in: snapshot)
        }
    }
}
