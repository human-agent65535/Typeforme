import Foundation

enum ClientBridgeRouteKind: String, Sendable {
    case local = "Local"
    case cloud = "Cloud"
    case unavailable = "Offline"
}

struct ClientBridgeRouteStatus: Sendable, Equatable {
    var activeKind: ClientBridgeRouteKind = .unavailable
    var activeURL: URL?
    var localOK = false
    var cloudOK = false
    var localChecked = false
    var cloudChecked = false
    var localLatencyMs: Int?
    var cloudLatencyMs: Int?
    var message = "Not checked"
}

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
        let resolved = await BridgeRouteResolutionCore(
            policy: .macClient,
            healthProbe: probe
        ).resolve(
            localBridgeURLs: config.localBridgeURLs,
            cloudBridgeURL: config.cloudBridgeURL,
            token: config.token,
            probeAllEndpoints: probeAllEndpoints
        )
        return ClientBridgeRouteStatus(resolved)
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

private extension ClientBridgeRouteStatus {
    init(_ resolved: BridgeRouteResolutionStatus) {
        self.init(
            activeKind: ClientBridgeRouteKind(resolved.activeKind),
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

private extension ClientBridgeRouteKind {
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
