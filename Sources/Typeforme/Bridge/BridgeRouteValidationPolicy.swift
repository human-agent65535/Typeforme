import Foundation

/// Defines when a previously resolved bridge route is still trustworthy.
/// Resolution and network probing stay with their callers; this policy only
/// evaluates cached evidence and probe coverage.
struct BridgeRouteValidationPolicy: Sendable, Equatable {
    let localCacheTTL: TimeInterval
    let nonLocalCacheTTL: TimeInterval

    static let iOSClient = BridgeRouteValidationPolicy(
        localCacheTTL: 5,
        nonLocalCacheTTL: 30
    )

    func cacheTTL(for kind: BridgeRouteResolutionKind) -> TimeInterval {
        kind == .local ? localCacheTTL : nonLocalCacheTTL
    }

    func isFresh(
        status: BridgeRouteResolutionStatus,
        fetchedAt: Date?,
        activeURL: URL? = nil,
        now: Date = Date()
    ) -> Bool {
        guard let fetchedAt, (activeURL ?? status.activeURL) != nil else { return false }
        return now.timeIntervalSince(fetchedAt) < cacheTTL(for: status.activeKind)
    }

    func cacheSatisfiesProbeMode(
        status: BridgeRouteResolutionStatus,
        probeAllEndpoints: Bool,
        localConfigured: Bool,
        cloudConfigured: Bool
    ) -> Bool {
        guard probeAllEndpoints else { return true }
        return (!localConfigured || status.localChecked) &&
            (!cloudConfigured || status.cloudChecked)
    }

    func canCommit(
        status: BridgeRouteResolutionStatus,
        localConfigured: Bool,
        cloudConfigured: Bool
    ) -> Bool {
        guard status.activeKind == .unavailable else { return true }
        return (!localConfigured || status.localChecked) &&
            (!cloudConfigured || status.cloudChecked)
    }

    func shouldPreflight(
        status: BridgeRouteResolutionStatus,
        routeIsFresh: Bool,
        requiresCurrentRouteEvidence: Bool = false
    ) -> Bool {
        if requiresCurrentRouteEvidence { return true }
        guard status.activeURL != nil else { return true }
        guard routeIsFresh else { return true }
        return status.activeKind == .local
    }
}
