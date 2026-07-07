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
}
