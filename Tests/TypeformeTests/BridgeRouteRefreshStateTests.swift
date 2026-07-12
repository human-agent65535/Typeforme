import Testing
@testable import Typeforme

@Suite("BridgeRouteRefreshState")
struct BridgeRouteRefreshStateTests {
    @Test func overlappingRefreshesKeepActivityUntilEachRefreshEnds() {
        var state = BridgeRouteRefreshState()

        let visible = state.begin(showIndicator: true)
        let background = state.begin(showIndicator: false)

        #expect(visible == BridgeRouteRefreshToken(generation: 1, pairingRevision: 0))
        #expect(background == BridgeRouteRefreshToken(generation: 2, pairingRevision: 0))
        #expect(state.isChecking)
        #expect(state.isRefreshing)

        state.end(showIndicator: false)
        #expect(state.isChecking)
        #expect(state.isRefreshing)

        state.end(showIndicator: true)
        #expect(!state.isChecking)
        #expect(!state.isRefreshing)
    }

    @Test func pairingChangeInvalidatesExistingGenerationWithoutEndingItsWork() {
        var state = BridgeRouteRefreshState()
        let existing = state.begin(showIndicator: true)

        state.pairingDidChange()

        #expect(state.pairingRevision == existing.pairingRevision + 1)
        #expect(state.generation == existing.generation + 1)
        #expect(state.isChecking)
        #expect(state.isRefreshing)

        let replacement = state.begin(showIndicator: false)
        #expect(replacement.pairingRevision == state.pairingRevision)
        #expect(replacement.generation == state.generation)

        state.end(showIndicator: false)
        state.end(showIndicator: true)
        #expect(!state.isChecking)
        #expect(!state.isRefreshing)
    }

    @Test func unmatchedEndCannotMakeCountersNegative() {
        var state = BridgeRouteRefreshState()

        state.end(showIndicator: true)

        #expect(!state.isChecking)
        #expect(!state.isRefreshing)
        #expect(state.begin(showIndicator: true).generation == 1)
    }
}

@Suite("Latest draft operation ownership")
struct LatestDraftOperationStateTests {
    @Test func newerOperationInvalidatesOlderResult() {
        var state = LatestDraftOperationState<String>()
        let first = state.begin(snapshot: "pairing-a")
        let second = state.begin(snapshot: "pairing-b")

        #expect(!state.canApply(first, to: "pairing-a"))
        #expect(state.canApply(second, to: "pairing-b"))
    }

    @Test func editingDraftInvalidatesInFlightResult() {
        var state = LatestDraftOperationState<String>()
        let operation = state.begin(snapshot: "pairing-a")

        state.draftDidChange(to: "pairing-b")

        #expect(!state.isActive)
        #expect(!state.canApply(operation, to: "pairing-b"))
    }

    @Test func staleCompletionCannotClearReplacement() {
        var state = LatestDraftOperationState<String>()
        let first = state.begin(snapshot: "pairing-a")
        let second = state.begin(snapshot: "pairing-b")

        state.finish(first)

        #expect(state.isActive)
        #expect(state.canApply(second, to: "pairing-b"))
    }
}
