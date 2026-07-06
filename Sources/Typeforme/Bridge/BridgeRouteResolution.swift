import Foundation

enum BridgeRouteResolutionKind: String, Sendable {
    case local = "Local"
    case cloud = "Cloud"
    case unavailable = "Offline"
}

struct BridgeRouteResolutionStatus: Sendable, Equatable {
    var activeKind: BridgeRouteResolutionKind = .unavailable
    var activeURL: URL?
    var localOK = false
    var cloudOK = false
    var localChecked = false
    var cloudChecked = false
    var localLatencyMs: Int?
    var cloudLatencyMs: Int?
    var message = "Not checked"
}

struct BridgeRouteProbeResult: Sendable, Equatable {
    var ok: Bool
    var latencyMs: Int?
}

struct BridgeRouteResolutionPolicy: Sendable, Equatable {
    var localTimeout: TimeInterval
    var localPriorityTimeoutWhenCloudAvailable: TimeInterval
    var cloudTimeout: TimeInterval
    var probeLocalAndCloudConcurrentlyWhenBothConfigured: Bool

    static let macClient = BridgeRouteResolutionPolicy(
        localTimeout: 1.5,
        localPriorityTimeoutWhenCloudAvailable: 0.75,
        cloudTimeout: 3.0,
        probeLocalAndCloudConcurrentlyWhenBothConfigured: true
    )

    static let iOSClient = BridgeRouteResolutionPolicy(
        localTimeout: 1.5,
        localPriorityTimeoutWhenCloudAvailable: 1.5,
        cloudTimeout: 3.0,
        probeLocalAndCloudConcurrentlyWhenBothConfigured: true
    )
}

typealias BridgeRouteHealthProbe = @Sendable (URL, String, TimeInterval) async -> BridgeRouteProbeResult

struct BridgeRouteResolutionCore: Sendable {
    let policy: BridgeRouteResolutionPolicy
    let healthProbe: BridgeRouteHealthProbe

    init(
        policy: BridgeRouteResolutionPolicy,
        healthProbe: @escaping BridgeRouteHealthProbe
    ) {
        self.policy = policy
        self.healthProbe = healthProbe
    }

    func resolve(
        localBridgeURLs: [String],
        cloudBridgeURL: String,
        token rawToken: String,
        probeAllEndpoints: Bool = false
    ) async -> BridgeRouteResolutionStatus {
        let localURLs = urls(from: localBridgeURLs)
        let cloudURL = url(from: cloudBridgeURL)
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)

        if probeAllEndpoints {
            return await resolveProbingAllEndpoints(
                localURLs: localURLs,
                cloudURL: cloudURL,
                token: token
            )
        }

        if !localURLs.isEmpty,
           let cloudURL,
           policy.probeLocalAndCloudConcurrentlyWhenBothConfigured {
            return await resolveConcurrentLocalAndCloud(
                localURLs: localURLs,
                cloudURL: cloudURL,
                token: token
            )
        }

        return await resolveInOrder(
            localURLs: localURLs,
            cloudURL: cloudURL,
            token: token
        )
    }

    private func resolveProbingAllEndpoints(
        localURLs: [URL],
        cloudURL: URL?,
        token: String
    ) async -> BridgeRouteResolutionStatus {
        var status = BridgeRouteResolutionStatus()
        async let localProbe = probeLocalIfNeeded(
            urls: localURLs,
            token: token,
            timeout: policy.localTimeout
        )
        async let cloudProbe = probeCloudIfNeeded(
            url: cloudURL,
            token: token,
            timeout: policy.cloudTimeout
        )
        let (local, cloud) = await (localProbe, cloudProbe)

        apply(local, to: &status)
        apply(cloud, to: &status)

        if let local, local.ok, let activeURL = local.url {
            activate(.local, url: activeURL, message: "Local", status: &status)
            return status
        }
        if let cloudURL, let cloud, cloud.ok {
            activate(.cloud, url: cloudURL, message: "Cloud", status: &status)
            return status
        }

        markUnavailable(&status)
        return status
    }

    private func resolveConcurrentLocalAndCloud(
        localURLs: [URL],
        cloudURL: URL,
        token: String
    ) async -> BridgeRouteResolutionStatus {
        var status = BridgeRouteResolutionStatus()
        async let localProbe = probeFirstAvailable(
            urls: localURLs,
            token: token,
            timeout: policy.localPriorityTimeoutWhenCloudAvailable
        )
        async let cloudProbe = healthProbe(cloudURL, token, policy.cloudTimeout)
        let local = await localProbe
        apply(local, to: &status)

        if local.ok, let activeURL = local.url {
            activate(.local, url: activeURL, message: "Local", status: &status)
            return status
        }

        let cloud = await cloudProbe
        apply(cloud, to: &status)
        if cloud.ok {
            activate(.cloud, url: cloudURL, message: "Cloud", status: &status)
            return status
        }

        markUnavailable(&status)
        return status
    }

    private func resolveInOrder(
        localURLs: [URL],
        cloudURL: URL?,
        token: String
    ) async -> BridgeRouteResolutionStatus {
        var status = BridgeRouteResolutionStatus()

        if !localURLs.isEmpty {
            let local = await probeFirstAvailable(
                urls: localURLs,
                token: token,
                timeout: policy.localTimeout
            )
            apply(local, to: &status)
            if local.ok, let activeURL = local.url {
                activate(.local, url: activeURL, message: "Local", status: &status)
                return status
            }
        }

        if let cloudURL {
            let cloud = await healthProbe(cloudURL, token, policy.cloudTimeout)
            apply(cloud, to: &status)
            if cloud.ok {
                activate(.cloud, url: cloudURL, message: "Cloud", status: &status)
                return status
            }
        }

        markUnavailable(&status)
        return status
    }

    private func probeLocalIfNeeded(
        urls: [URL],
        token: String,
        timeout: TimeInterval
    ) async -> LocalProbeResult? {
        guard !urls.isEmpty else { return nil }
        return await probeFirstAvailable(urls: urls, token: token, timeout: timeout)
    }

    private func probeCloudIfNeeded(
        url: URL?,
        token: String,
        timeout: TimeInterval
    ) async -> BridgeRouteProbeResult? {
        guard let url else { return nil }
        return await healthProbe(url, token, timeout)
    }

    private func probeFirstAvailable(
        urls: [URL],
        token: String,
        timeout: TimeInterval
    ) async -> LocalProbeResult {
        await withTaskGroup(of: LocalProbeResult.self) { group in
            for url in urls {
                group.addTask {
                    let result = await healthProbe(url, token, timeout)
                    return LocalProbeResult(
                        url: url,
                        ok: result.ok,
                        latencyMs: result.latencyMs
                    )
                }
            }

            while let result = await group.next() {
                if result.ok {
                    group.cancelAll()
                    return result
                }
            }
            return LocalProbeResult(url: nil, ok: false, latencyMs: nil)
        }
    }

    private func url(from rawValue: String) -> URL? {
        let normalized = BridgeBaseURLNormalizer.normalizedBaseURL(rawValue)
        guard !normalized.isEmpty else { return nil }
        return URL(string: normalized)
    }

    private func urls(from rawValues: [String]) -> [URL] {
        BridgeBaseURLNormalizer.uniqueBridgeURLs(rawValues).compactMap { URL(string: $0) }
    }

    private func apply(_ local: LocalProbeResult?, to status: inout BridgeRouteResolutionStatus) {
        guard let local else { return }
        status.localChecked = true
        status.localOK = local.ok
        status.localLatencyMs = local.latencyMs
    }

    private func apply(_ cloud: BridgeRouteProbeResult?, to status: inout BridgeRouteResolutionStatus) {
        guard let cloud else { return }
        status.cloudChecked = true
        status.cloudOK = cloud.ok
        status.cloudLatencyMs = cloud.latencyMs
    }

    private func activate(
        _ kind: BridgeRouteResolutionKind,
        url: URL,
        message: String,
        status: inout BridgeRouteResolutionStatus
    ) {
        status.activeKind = kind
        status.activeURL = url
        status.message = message
    }

    private func markUnavailable(_ status: inout BridgeRouteResolutionStatus) {
        status.activeKind = .unavailable
        status.activeURL = nil
        status.message = "Unavailable"
    }
}

private struct LocalProbeResult: Sendable, Equatable {
    var url: URL?
    var ok: Bool
    var latencyMs: Int?
}
