import Testing
@testable import Typeforme

@Suite("KeyboardStartHandshakePolicy")
struct KeyboardStartHandshakePolicyTests {
    @Test func ignoresIdleWithoutCommandWhileStartIsInFlight() {
        let snapshot = KeyboardStartHandshakePolicy.Snapshot(
            isStartRequestInFlight: true,
            pendingStartCommandID: "start-1",
            activeRecordingCommandID: "start-1",
            pendingDarwinStartAckCommandID: nil,
            trackedStartCommandIDs: ["start-1"]
        )

        #expect(KeyboardStartHandshakePolicy.shouldIgnoreStatusDuringStart(
            state: .idle,
            commandID: nil,
            snapshot: snapshot
        ))
    }

    @Test func ignoresStandbyWithoutCommandWhileWaitingForRecordingReceipt() {
        let snapshot = KeyboardStartHandshakePolicy.Snapshot(
            isStartRequestInFlight: true,
            pendingStartCommandID: "start-1",
            activeRecordingCommandID: "start-1",
            pendingDarwinStartAckCommandID: nil,
            trackedStartCommandIDs: ["start-1"]
        )

        #expect(KeyboardStartHandshakePolicy.shouldIgnoreStatusDuringStart(
            state: .standby,
            commandID: nil,
            snapshot: snapshot
        ))
    }

    @Test func acceptsRecordingForTrackedCommandAfterPendingWasCleared() {
        let snapshot = KeyboardStartHandshakePolicy.Snapshot(
            isStartRequestInFlight: true,
            pendingStartCommandID: nil,
            activeRecordingCommandID: nil,
            pendingDarwinStartAckCommandID: nil,
            trackedStartCommandIDs: ["start-1"]
        )

        #expect(!KeyboardStartHandshakePolicy.shouldIgnoreStatusDuringStart(
            state: .recording,
            commandID: "start-1",
            snapshot: snapshot
        ))
        #expect(KeyboardStartHandshakePolicy.isTrackedStartCommandID("start-1", in: snapshot))
    }

    @Test func ignoresRecordingForUnknownCommandDuringStart() {
        let snapshot = KeyboardStartHandshakePolicy.Snapshot(
            isStartRequestInFlight: true,
            pendingStartCommandID: "start-1",
            activeRecordingCommandID: "start-1",
            pendingDarwinStartAckCommandID: nil,
            trackedStartCommandIDs: ["start-1"]
        )

        #expect(KeyboardStartHandshakePolicy.shouldIgnoreStatusDuringStart(
            state: .recording,
            commandID: "old-start",
            snapshot: snapshot
        ))
    }

    @Test func ignoresUnscopedAndMismatchedTerminalStatusesDuringStart() {
        let snapshot = KeyboardStartHandshakePolicy.Snapshot(
            isStartRequestInFlight: true,
            pendingStartCommandID: "start-1",
            activeRecordingCommandID: "start-1",
            pendingDarwinStartAckCommandID: nil,
            trackedStartCommandIDs: ["start-1"]
        )

        for state in [
            KeyboardStartHandshakePolicy.StatusState.sending,
            .result,
            .error,
        ] {
            #expect(KeyboardStartHandshakePolicy.shouldIgnoreStatusDuringStart(
                state: state,
                commandID: nil,
                snapshot: snapshot
            ))
            #expect(KeyboardStartHandshakePolicy.shouldIgnoreStatusDuringStart(
                state: state,
                commandID: "old-start",
                snapshot: snapshot
            ))
            #expect(!KeyboardStartHandshakePolicy.shouldIgnoreStatusDuringStart(
                state: state,
                commandID: "start-1",
                snapshot: snapshot
            ))
        }
    }

    @Test func allowsIdleWhenNoStartHandshakeIsActive() {
        let snapshot = KeyboardStartHandshakePolicy.Snapshot(
            isStartRequestInFlight: false,
            pendingStartCommandID: nil,
            activeRecordingCommandID: nil,
            pendingDarwinStartAckCommandID: nil,
            trackedStartCommandIDs: []
        )

        #expect(!KeyboardStartHandshakePolicy.shouldIgnoreStatusDuringStart(
            state: .idle,
            commandID: nil,
            snapshot: snapshot
        ))
    }

    @Test func newerCommandSupersedesCurrentCommand() {
        let admission = KeyboardCommandLifecyclePolicy.admission(
            current: KeyboardCommandToken(id: "command-a", issuedAt: 10),
            incoming: KeyboardCommandToken(id: "command-b", issuedAt: 11)
        )

        #expect(admission == .accepted(supersededCommandID: "command-a"))
    }

    @Test func duplicateAndOlderCommandsNeverReplaceCurrentCommand() {
        let current = KeyboardCommandToken(id: "command-b", issuedAt: 11)

        #expect(KeyboardCommandLifecyclePolicy.admission(
            current: current,
            incoming: KeyboardCommandToken(id: "command-b", issuedAt: 12)
        ) == .duplicate)
        #expect(KeyboardCommandLifecyclePolicy.admission(
            current: current,
            incoming: KeyboardCommandToken(id: "command-a", issuedAt: 10)
        ) == .stale)
    }

    @Test func lifecycleAllowsOnlyForwardProgressOrTerminalExit() {
        #expect(KeyboardCommandLifecyclePolicy.canTransition(from: .accepted, to: .preparing))
        #expect(KeyboardCommandLifecyclePolicy.canTransition(from: .accepted, to: .refining))
        #expect(KeyboardCommandLifecyclePolicy.canTransition(from: .preparing, to: .recording))
        #expect(KeyboardCommandLifecyclePolicy.canTransition(from: .recording, to: .transcribing))
        #expect(KeyboardCommandLifecyclePolicy.canTransition(from: .transcribing, to: .refining))
        #expect(KeyboardCommandLifecyclePolicy.canTransition(from: .refining, to: .completed))
        #expect(KeyboardCommandLifecyclePolicy.canTransition(from: .recording, to: .failed))
        #expect(KeyboardCommandLifecyclePolicy.canTransition(from: .transcribing, to: .cancelled))

        #expect(!KeyboardCommandLifecyclePolicy.canTransition(from: .recording, to: .preparing))
        #expect(!KeyboardCommandLifecyclePolicy.canTransition(from: .completed, to: .recording))
        #expect(!KeyboardCommandLifecyclePolicy.canTransition(from: .failed, to: .completed))
    }

    @Test func captureEventsFailCaptureButPreserveNetworkProcessing() {
        for event in [
            KeyboardCommandCaptureEvent.audioInterrupted,
            .mediaServicesReset,
            .pictureInPictureClosed,
        ] {
            #expect(KeyboardCommandCaptureEventPolicy.effect(of: event, during: .preparing) != .preserveProcessing)
            #expect(KeyboardCommandCaptureEventPolicy.effect(of: event, during: .recording) != .preserveProcessing)
            #expect(KeyboardCommandCaptureEventPolicy.effect(of: event, during: .transcribing) == .preserveProcessing)
            #expect(KeyboardCommandCaptureEventPolicy.effect(of: event, during: .refining) == .preserveProcessing)
            #expect(KeyboardCommandCaptureEventPolicy.effect(of: event, during: .completed) == .ignore)
        }

        #expect(KeyboardCommandCaptureEventPolicy.effect(
            of: .audioInterrupted,
            during: .recording
        ) == .fail(.audioInterrupted))
        #expect(KeyboardCommandCaptureEventPolicy.effect(
            of: .mediaServicesReset,
            during: .recording
        ) == .fail(.mediaServicesReset))
        #expect(KeyboardCommandCaptureEventPolicy.effect(
            of: .pictureInPictureClosed,
            during: .recording
        ) == .fail(.pictureInPictureClosed))
    }

    @Test func onlyLatestCommandCanPublishStatus() {
        let lifecycle = KeyboardCommandLifecycleSnapshot(
            command: KeyboardCommandToken(id: "command-b", issuedAt: 11),
            stage: .recording
        )

        #expect(KeyboardCommandLifecyclePolicy.canPublishStatus(
            commandID: "command-b",
            state: .recording,
            lifecycle: lifecycle
        ))
        #expect(!KeyboardCommandLifecyclePolicy.canPublishStatus(
            commandID: "command-a",
            state: .result,
            lifecycle: lifecycle
        ))
    }

    @Test func terminalLifecycleCannotBeOverwrittenByCapabilityStatus() {
        let token = KeyboardCommandToken(id: "command-a", issuedAt: 10)
        let completed = KeyboardCommandLifecycleSnapshot(command: token, stage: .completed)
        let failed = KeyboardCommandLifecycleSnapshot(
            command: token,
            stage: .failed,
            failureCode: .processingFailed,
            recovery: .retry
        )

        #expect(KeyboardCommandLifecyclePolicy.canPublishStatus(
            commandID: token.id,
            state: .result,
            lifecycle: completed
        ))
        #expect(!KeyboardCommandLifecyclePolicy.canPublishStatus(
            commandID: token.id,
            state: .standby,
            lifecycle: completed
        ))
        #expect(KeyboardCommandLifecyclePolicy.canPublishStatus(
            commandID: token.id,
            state: .error,
            lifecycle: failed
        ))
        #expect(!KeyboardCommandLifecyclePolicy.canPublishStatus(
            commandID: token.id,
            state: .idle,
            lifecycle: failed
        ))
    }

    @Test func stopOnlyEndsCaptureAndNeverCancelsProcessing() {
        #expect(KeyboardCommandControlPolicy.stopEffect(during: .accepted) == .cancelBeforeRecording)
        #expect(KeyboardCommandControlPolicy.stopEffect(during: .preparing) == .cancelBeforeRecording)
        #expect(KeyboardCommandControlPolicy.stopEffect(during: .recording) == .stopAndProcess)
        #expect(KeyboardCommandControlPolicy.stopEffect(during: .transcribing) == .ignore)
        #expect(KeyboardCommandControlPolicy.stopEffect(during: .refining) == .ignore)
        #expect(KeyboardCommandControlPolicy.stopEffect(during: .completed) == .ignore)
        #expect(KeyboardCommandControlPolicy.stopEffect(during: .cancelled) == .ignore)
        #expect(KeyboardCommandControlPolicy.stopEffect(during: .failed) == .ignore)
    }
}
