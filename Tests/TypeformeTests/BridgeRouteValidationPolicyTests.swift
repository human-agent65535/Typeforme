import Foundation
import Testing
@testable import Typeforme

@Suite("BridgeRouteValidationPolicy")
struct BridgeRouteValidationPolicyTests {
    private let policy = BridgeRouteValidationPolicy.iOSClient
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func localAndCloudCacheUseTheirExistingTTLBoundaries() {
        let local = status(kind: .local, url: "http://192.168.1.8:18081")
        let cloud = status(kind: .cloud, url: "https://bridge.example.com")

        #expect(policy.isFresh(status: local, fetchedAt: now.addingTimeInterval(-4.999), now: now))
        #expect(!policy.isFresh(status: local, fetchedAt: now.addingTimeInterval(-5), now: now))
        #expect(policy.isFresh(status: cloud, fetchedAt: now.addingTimeInterval(-29.999), now: now))
        #expect(!policy.isFresh(status: cloud, fetchedAt: now.addingTimeInterval(-30), now: now))
    }

    @Test func freshnessRequiresAValidatedTimeAndActiveURL() {
        let offline = BridgeRouteResolutionStatus()
        let cloud = status(kind: .cloud, url: "https://bridge.example.com")

        #expect(!policy.isFresh(status: offline, fetchedAt: now, now: now))
        #expect(!policy.isFresh(status: cloud, fetchedAt: nil, now: now))
    }

    @Test func fullProbeCacheRequiresEveryConfiguredRouteToHaveBeenChecked() {
        var localOnly = status(kind: .local, url: "http://192.168.1.8:18081")
        localOnly.localChecked = true

        #expect(policy.cacheSatisfiesProbeMode(
            status: localOnly,
            probeAllEndpoints: false,
            localConfigured: true,
            cloudConfigured: true
        ))
        #expect(!policy.cacheSatisfiesProbeMode(
            status: localOnly,
            probeAllEndpoints: true,
            localConfigured: true,
            cloudConfigured: true
        ))

        localOnly.cloudChecked = true
        #expect(policy.cacheSatisfiesProbeMode(
            status: localOnly,
            probeAllEndpoints: true,
            localConfigured: true,
            cloudConfigured: true
        ))
    }

    @Test func unavailableResultCannotReplaceStatusWithIncompleteProbeCoverage() {
        var unavailable = BridgeRouteResolutionStatus()
        unavailable.localChecked = true

        #expect(!policy.canCommit(
            status: unavailable,
            localConfigured: true,
            cloudConfigured: true
        ))

        unavailable.cloudChecked = true
        #expect(policy.canCommit(
            status: unavailable,
            localConfigured: true,
            cloudConfigured: true
        ))

        let local = status(kind: .local, url: "http://192.168.1.8:18081")
        #expect(policy.canCommit(
            status: local,
            localConfigured: true,
            cloudConfigured: true
        ))
    }

    @Test func localAlwaysPreflightsWhileFreshCloudCanBeReused() {
        let local = status(kind: .local, url: "http://192.168.1.8:18081")
        let cloud = status(kind: .cloud, url: "https://bridge.example.com")
        let offline = BridgeRouteResolutionStatus()

        #expect(policy.shouldPreflight(status: local, routeIsFresh: true))
        #expect(!policy.shouldPreflight(status: cloud, routeIsFresh: true))
        #expect(policy.shouldPreflight(status: cloud, routeIsFresh: false))
        #expect(policy.shouldPreflight(status: offline, routeIsFresh: true))
    }

    @Test func aRecordedKeyboardJobAlwaysValidatesItsRouteBeforeTheOnlyUpload() {
        let freshCloud = status(kind: .cloud, url: "https://bridge.example.com")

        #expect(policy.shouldPreflight(
            status: freshCloud,
            routeIsFresh: true,
            requiresCurrentRouteEvidence: true
        ))
    }

    private func status(kind: BridgeRouteResolutionKind, url: String) -> BridgeRouteResolutionStatus {
        BridgeRouteResolutionStatus(
            activeKind: kind,
            activeURL: URL(string: url),
            message: kind.rawValue
        )
    }
}
