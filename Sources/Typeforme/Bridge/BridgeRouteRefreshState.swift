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
