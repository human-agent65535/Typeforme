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

    @Test func completedCommandCannotFinalizeOverANewerOwner() {
        #expect(!KeyboardCommandCompletionPolicy.finishedCommandCanFinalizeSharedState(
            finishedCommandID: "command-a",
            activeCommandID: "command-b"
        ))
        #expect(!KeyboardCommandCompletionPolicy.shouldRecoverStandby(
            finishedCommandID: "command-a",
            activeCommandID: "command-b",
            statusCommandID: "command-a",
            statusIsSending: true
        ))
    }

    @Test func incompleteOwnerRestoresStandbyButTerminalResultDoesNot() {
        #expect(KeyboardCommandCompletionPolicy.shouldRecoverStandby(
            finishedCommandID: "command-a",
            activeCommandID: "command-a",
            statusCommandID: "command-a",
            statusIsSending: true
        ))
        #expect(!KeyboardCommandCompletionPolicy.shouldRecoverStandby(
            finishedCommandID: "command-a",
            activeCommandID: "command-a",
            statusCommandID: "command-a",
            statusIsSending: false
        ))
    }
}
