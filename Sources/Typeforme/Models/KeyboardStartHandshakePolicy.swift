import Foundation

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

enum KeyboardCommandLifecycleStage: String, Codable, CaseIterable, Sendable {
    case accepted
    case preparing
    case recording
    case transcribing
    case refining
    case completed
    case cancelled
    case failed

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            return true
        case .accepted, .preparing, .recording, .transcribing, .refining:
            return false
        }
    }
}

enum KeyboardCommandFailureCode: String, Codable, Sendable {
    case microphonePermissionDenied = "microphone_permission_denied"
    case microphoneUnavailable = "microphone_unavailable"
    case audioInterrupted = "audio_interrupted"
    case mediaServicesReset = "media_services_reset"
    case hostRestarted = "host_restarted"
    case pictureInPictureClosed = "picture_in_picture_closed"
    case bridgeUnavailable = "bridge_unavailable"
    case commandExpired = "command_expired"
    case hostBusy = "host_busy"
    case emptyRecording = "empty_recording"
    case processingFailed = "processing_failed"
    case unknown
}

enum KeyboardCommandRecovery: String, Codable, Sendable {
    case none
    case retry
    case openHost = "open_host"
    case openSettings = "open_settings"
}

struct KeyboardCommandToken: Codable, Equatable, Sendable {
    let id: String
    let issuedAt: TimeInterval

    init(id: String, issuedAt: TimeInterval) {
        self.id = id
        self.issuedAt = issuedAt
    }
}

struct KeyboardCommandLifecycleSnapshot: Codable, Equatable, Sendable {
    let revisionID: String
    let command: KeyboardCommandToken
    let stage: KeyboardCommandLifecycleStage
    let failureCode: KeyboardCommandFailureCode?
    let recovery: KeyboardCommandRecovery
    let message: String?
    let updatedAt: TimeInterval

    init(
        revisionID: String = UUID().uuidString,
        command: KeyboardCommandToken,
        stage: KeyboardCommandLifecycleStage,
        failureCode: KeyboardCommandFailureCode? = nil,
        recovery: KeyboardCommandRecovery = .none,
        message: String? = nil,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        precondition(
            stage == .failed || failureCode == nil,
            "Only a failed command lifecycle may carry a failure code"
        )
        self.revisionID = revisionID
        self.command = command
        self.stage = stage
        self.failureCode = failureCode
        self.recovery = recovery
        self.message = message.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        }
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case revisionID = "revision_id"
        case command
        case stage
        case failureCode = "failure_code"
        case recovery
        case message
        case updatedAt = "updated_at"
    }
}

enum KeyboardCommandAdmission: Equatable {
    case accepted(supersededCommandID: String?)
    case duplicate
    case stale
}

enum KeyboardCommandLifecyclePolicy {
    static func admission(
        current: KeyboardCommandToken?,
        incoming: KeyboardCommandToken
    ) -> KeyboardCommandAdmission {
        guard let current else {
            return .accepted(supersededCommandID: nil)
        }
        if current.id == incoming.id {
            return .duplicate
        }
        guard incoming.issuedAt > current.issuedAt else {
            return .stale
        }
        return .accepted(supersededCommandID: current.id)
    }

    static func canTransition(
        from current: KeyboardCommandLifecycleStage,
        to next: KeyboardCommandLifecycleStage
    ) -> Bool {
        guard !current.isTerminal else { return false }
        if next == .cancelled || next == .failed {
            return true
        }
        switch (current, next) {
        case (.accepted, .preparing),
             (.accepted, .recording),
             (.accepted, .refining),
             (.preparing, .recording),
             (.recording, .transcribing),
             (.transcribing, .refining),
             (.transcribing, .completed),
             (.refining, .completed):
            return true
        default:
            return false
        }
    }

    static func canPublishStatus(
        commandID: String,
        state: KeyboardStartHandshakePolicy.StatusState,
        lifecycle: KeyboardCommandLifecycleSnapshot?
    ) -> Bool {
        guard let lifecycle else { return true }
        guard commandID == lifecycle.command.id else { return false }
        switch lifecycle.stage {
        case .completed:
            return state == .result
        case .failed:
            return state == .error
        case .cancelled:
            return state == .idle || state == .standby
        case .accepted, .preparing, .recording, .transcribing, .refining:
            return true
        }
    }
}

enum KeyboardCommandCaptureEvent: Sendable {
    case audioInterrupted
    case mediaServicesReset
    case pictureInPictureClosed
}

enum KeyboardCommandCaptureEventEffect: Equatable, Sendable {
    case fail(KeyboardCommandFailureCode)
    case preserveProcessing
    case ignore
}

enum KeyboardCommandCaptureEventPolicy {
    static func effect(
        of event: KeyboardCommandCaptureEvent,
        during stage: KeyboardCommandLifecycleStage?
    ) -> KeyboardCommandCaptureEventEffect {
        guard let stage else { return .ignore }
        switch stage {
        case .accepted, .preparing, .recording:
            switch event {
            case .audioInterrupted:
                return .fail(.audioInterrupted)
            case .mediaServicesReset:
                return .fail(.mediaServicesReset)
            case .pictureInPictureClosed:
                return .fail(.pictureInPictureClosed)
            }
        case .transcribing, .refining:
            return .preserveProcessing
        case .completed, .cancelled, .failed:
            return .ignore
        }
    }
}

enum KeyboardCommandStopEffect: Equatable, Sendable {
    case cancelBeforeRecording
    case stopAndProcess
    case ignore
}

enum KeyboardCommandControlPolicy {
    static func stopEffect(
        during stage: KeyboardCommandLifecycleStage
    ) -> KeyboardCommandStopEffect {
        switch stage {
        case .accepted, .preparing:
            return .cancelBeforeRecording
        case .recording:
            return .stopAndProcess
        case .transcribing, .refining, .completed, .cancelled, .failed:
            return .ignore
        }
    }
}
