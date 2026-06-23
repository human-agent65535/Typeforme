import Foundation

typealias BridgeRouteKind = BridgeRouteResolutionKind
typealias BridgeRouteStatus = BridgeRouteResolutionStatus

struct BridgeRouteResolver {
    func resolve(config: PairingConfig, probeAllEndpoints: Bool = false) async -> BridgeRouteStatus {
        await BridgeRouteResolutionCore(
            policy: .iOSClient,
            healthProbe: probe
        ).resolve(
            localBridgeURLs: config.localBridgeURLCandidates,
            cloudBridgeURL: config.publicBridgeURL,
            token: config.token,
            probeAllEndpoints: probeAllEndpoints
        )
    }

    private func probe(url: URL, token: String, timeout: TimeInterval) async -> BridgeRouteProbeResult {
        let start = Date()
        let ok = await BridgeClient(baseURL: url, token: token).health(timeout: timeout)
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        return BridgeRouteProbeResult(ok: ok, latencyMs: ok ? latency : nil)
    }
}
