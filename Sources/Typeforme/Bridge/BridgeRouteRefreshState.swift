struct BridgeRouteRefreshToken: Equatable {
    let generation: UInt64
    let pairingRevision: UInt64
}

/// Tracks route refresh ownership independently from the network work itself.
/// A newer refresh or pairing change invalidates older results, while the
/// in-flight counters keep UI state accurate until every started refresh ends.
struct BridgeRouteRefreshState: Equatable {
    private(set) var pairingRevision: UInt64 = 0
    private(set) var generation: UInt64 = 0
    private var probeInFlightCount = 0
    private var indicatorInFlightCount = 0

    var isChecking: Bool {
        probeInFlightCount > 0
    }

    var isRefreshing: Bool {
        indicatorInFlightCount > 0
    }

    mutating func pairingDidChange() {
        pairingRevision &+= 1
        generation &+= 1
    }

    mutating func begin(showIndicator: Bool) -> BridgeRouteRefreshToken {
        generation &+= 1
        probeInFlightCount += 1
        if showIndicator {
            indicatorInFlightCount += 1
        }
        return BridgeRouteRefreshToken(
            generation: generation,
            pairingRevision: pairingRevision
        )
    }

    mutating func end(showIndicator: Bool) {
        probeInFlightCount = max(0, probeInFlightCount - 1)
        if showIndicator {
            indicatorInFlightCount = max(0, indicatorInFlightCount - 1)
        }
    }
}

/// Owns one replaceable async operation against an editable draft. Cancellation
/// remains best-effort; the token and snapshot are the commit authority when an
/// older request returns after a newer draft has replaced it.
struct LatestDraftOperationState<Snapshot: Equatable>: Equatable {
    struct Token: Equatable {
        fileprivate let generation: UInt64
    }

    private(set) var activeToken: Token?
    private(set) var activeSnapshot: Snapshot?
    private var generation: UInt64 = 0

    var isActive: Bool { activeToken != nil }

    mutating func begin(snapshot: Snapshot) -> Token {
        generation &+= 1
        let token = Token(generation: generation)
        activeToken = token
        activeSnapshot = snapshot
        return token
    }

    func canApply(_ token: Token, to currentSnapshot: Snapshot) -> Bool {
        activeToken == token && activeSnapshot == currentSnapshot
    }

    mutating func finish(_ token: Token) {
        guard activeToken == token else { return }
        activeToken = nil
        activeSnapshot = nil
    }

    mutating func draftDidChange(to snapshot: Snapshot) {
        guard let activeSnapshot, activeSnapshot != snapshot else { return }
        invalidate()
    }

    mutating func invalidate() {
        generation &+= 1
        activeToken = nil
        activeSnapshot = nil
    }
}
