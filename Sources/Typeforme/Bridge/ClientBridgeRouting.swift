import Foundation

typealias ClientBridgeRouteKind = BridgeRouteResolutionKind
typealias ClientBridgeRouteStatus = BridgeRouteResolutionStatus

struct ClientBridgeConfiguration: Sendable, Equatable {
    var localBridgeURLs: [String]
    var cloudBridgeURL: String
    var token: String

    var hasAnyBridgeURL: Bool {
        !localBridgeURLs.isEmpty || !cloudBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isConfigured: Bool {
        hasAnyBridgeURL && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var current: ClientBridgeConfiguration {
        ClientBridgeConfiguration(
            localBridgeURLs: AppSettings.clientLocalBridgeURLs,
            cloudBridgeURL: AppSettings.clientCloudBridgeURL,
            token: AppSettings.clientBridgeToken
        )
    }

    static func uniqueBridgeURLs(_ rawValues: [String]) -> [String] {
        BridgeBaseURLNormalizer.uniqueBridgeURLs(rawValues)
    }

    static func rawValue(for urls: [String]) -> String {
        uniqueBridgeURLs(urls).joined(separator: "\n")
    }

    static func normalizedBaseURL(_ rawValue: String) -> String {
        BridgeBaseURLNormalizer.normalizedBaseURL(rawValue)
    }

    static func fromPairingPayload(_ payload: BridgePairingPayload) -> ClientBridgeConfiguration {
        return ClientBridgeConfiguration(
            localBridgeURLs: payload.localBridgeURLCandidates,
            cloudBridgeURL: payload.normalizedPublicBridgeURL,
            token: payload.token
        )
    }
}

struct ClientBridgeRouteResolver {
    func resolve(
        config: ClientBridgeConfiguration = .current,
        probeAllEndpoints: Bool = false
    ) async -> ClientBridgeRouteStatus {
        await BridgeRouteResolutionCore(
            policy: .macClient,
            healthProbe: probe
        ).resolve(
            localBridgeURLs: config.localBridgeURLs,
            cloudBridgeURL: config.cloudBridgeURL,
            token: config.token,
            probeAllEndpoints: probeAllEndpoints
        )
    }

    private func probe(url: URL, token: String, timeout: TimeInterval) async -> BridgeRouteProbeResult {
        let start = Date()
        do {
            let client = try RemoteBridgeClient(baseURLString: url.absoluteString, token: token)
            let health = try await client.health(timeout: timeout)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            return BridgeRouteProbeResult(ok: health.ok, latencyMs: health.ok ? latency : nil)
        } catch {
            return BridgeRouteProbeResult(ok: false, latencyMs: nil)
        }
    }
}
