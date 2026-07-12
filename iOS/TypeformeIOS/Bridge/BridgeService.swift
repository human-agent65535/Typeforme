import Foundation

struct PairingRouteCheckResult {
    let routeStatus: BridgeRouteResolutionStatus
    let bridgeEndpoints: BridgeEndpoints
}

struct PairingSettingsRefreshResult {
    let routeStatus: BridgeRouteResolutionStatus
    let bridgeEndpoints: BridgeEndpoints
    let macSettings: BridgeMacSettingsPayload
}

struct PairingSettingsRefreshUnavailable: LocalizedError {
    let routeStatus: BridgeRouteResolutionStatus

    var errorDescription: String? {
        BridgeClientError.unauthorizedOrUnavailable.localizedDescription
    }
}

@MainActor
final class BridgeService {
    let store = PairingStore()
    let routeResolver = BridgeRouteResolver()

    func checkPairingRoutes(_ config: PairingConfig) async -> PairingRouteCheckResult {
        let routeStatus = await routeResolver.resolve(config: config, probeAllEndpoints: true)
        let bridgeEndpoints = await refreshedBridgeEndpoints(
            for: config,
            routeStatus: routeStatus
        )
        return PairingRouteCheckResult(
            routeStatus: routeStatus,
            bridgeEndpoints: bridgeEndpoints
        )
    }

    func refreshPairingSettings(_ config: PairingConfig) async throws -> PairingSettingsRefreshResult {
        let routeStatus = await routeResolver.resolve(config: config, probeAllEndpoints: true)
        guard let activeURL = routeStatus.activeURL else {
            throw PairingSettingsRefreshUnavailable(routeStatus: routeStatus)
        }

        let client = BridgeClient(baseURL: activeURL, token: config.token)
        let bridgeEndpoints = await refreshedBridgeEndpoints(
            for: config,
            routeStatus: routeStatus,
            client: client
        )
        var macSettings = try await client.macSettings()
        macSettings.normalize()
        return PairingSettingsRefreshResult(
            routeStatus: routeStatus,
            bridgeEndpoints: bridgeEndpoints,
            macSettings: macSettings
        )
    }

    private func refreshedBridgeEndpoints(
        for config: PairingConfig,
        routeStatus: BridgeRouteResolutionStatus,
        client existingClient: BridgeClient? = nil
    ) async -> BridgeEndpoints {
        var refreshed = config
        if let activeURL = routeStatus.activeURL {
            let client = existingClient ?? BridgeClient(baseURL: activeURL, token: config.token)
            if let remoteConfig = try? await client.pairing(timeout: 4) {
                refreshed.bridgeEndpoints = remoteConfig.bridgeEndpoints
            } else if routeStatus.activeKind == .local {
                refreshed.promoteLocalBridgeURL(activeURL.absoluteString)
            }
        }
        refreshed.normalizeBridgeEndpoints()
        return refreshed.bridgeEndpoints
    }
}
