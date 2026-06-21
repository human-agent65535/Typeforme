import Foundation

enum BridgeRouteKind: String {
    case local = "Local"
    case cloud = "Cloud"
    case unavailable = "Offline"
}

struct BridgeRouteStatus {
    var activeKind: BridgeRouteKind = .unavailable
    var activeURL: URL?
    var localOK = false
    var cloudOK = false
    var localChecked = false
    var cloudChecked = false
    var localLatencyMs: Int?
    var cloudLatencyMs: Int?
    var message = "Not checked"
}

struct BridgeRouteResolver {
    func resolve(config: PairingConfig, probeAllEndpoints: Bool = false) async -> BridgeRouteStatus {
        let resolved = await BridgeRouteResolutionCore(
            policy: .iOSClient,
            healthProbe: probe
        ).resolve(
            localBridgeURLs: config.localBridgeURLCandidates,
            cloudBridgeURL: config.publicBridgeURL,
            token: config.token,
            probeAllEndpoints: probeAllEndpoints
        )
        return BridgeRouteStatus(resolved)
    }

    private func probe(url: URL, token: String, timeout: TimeInterval) async -> BridgeRouteProbeResult {
        let start = Date()
        let ok = await BridgeClient(baseURL: url, token: token).health(timeout: timeout)
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        return BridgeRouteProbeResult(ok: ok, latencyMs: ok ? latency : nil)
    }
}

private extension BridgeRouteStatus {
    init(_ resolved: BridgeRouteResolutionStatus) {
        self.init(
            activeKind: BridgeRouteKind(resolved.activeKind),
            activeURL: resolved.activeURL,
            localOK: resolved.localOK,
            cloudOK: resolved.cloudOK,
            localChecked: resolved.localChecked,
            cloudChecked: resolved.cloudChecked,
            localLatencyMs: resolved.localLatencyMs,
            cloudLatencyMs: resolved.cloudLatencyMs,
            message: resolved.message
        )
    }
}

private extension BridgeRouteKind {
    init(_ kind: BridgeRouteResolutionKind) {
        switch kind {
        case .local:
            self = .local
        case .cloud:
            self = .cloud
        case .unavailable:
            self = .unavailable
        }
    }
}
