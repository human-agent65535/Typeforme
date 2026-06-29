import Foundation
import Testing
@testable import Typeforme

@Suite("BridgeRouteResolution")
struct BridgeRouteResolutionTests {
    @Test func fullProbeMarksBothEndpointsAndPrefersLocalWhenBothPass() async {
        let resolver = BridgeRouteResolutionCore(policy: .macClient) { url, _, _ in
            BridgeRouteProbeResult(ok: url.host != nil, latencyMs: url.host == "192.168.1.8" ? 12 : 30)
        }

        let status = await resolver.resolve(
            localBridgeURLs: ["192.168.1.8:18081"],
            cloudBridgeURL: "bridge.example.com",
            token: " token ",
            probeAllEndpoints: true
        )

        #expect(status.activeKind == .local)
        #expect(status.activeURL?.absoluteString == "http://192.168.1.8:18081")
        #expect(status.localChecked)
        #expect(status.cloudChecked)
        #expect(status.localOK)
        #expect(status.cloudOK)
        #expect(status.localLatencyMs == 12)
        #expect(status.cloudLatencyMs == 30)
    }

    @Test func usesCloudWhenLocalFails() async {
        let resolver = BridgeRouteResolutionCore(policy: .macClient) { url, _, _ in
            BridgeRouteProbeResult(ok: url.host == "bridge.example.com", latencyMs: url.host == "bridge.example.com" ? 31 : nil)
        }

        let status = await resolver.resolve(
            localBridgeURLs: ["192.168.1.8:18081"],
            cloudBridgeURL: "bridge.example.com",
            token: "token"
        )

        #expect(status.activeKind == .cloud)
        #expect(status.activeURL?.absoluteString == "https://bridge.example.com")
        #expect(status.localChecked)
        #expect(status.cloudChecked)
        #expect(!status.localOK)
        #expect(status.cloudOK)
        #expect(status.cloudLatencyMs == 31)
    }

    @Test func macPolicyUsesPriorityTimeoutWhenBothRoutesAreConfigured() async {
        let log = ProbeLog()
        let resolver = BridgeRouteResolutionCore(policy: .macClient) { url, token, timeout in
            await log.record(url: url.absoluteString, token: token, timeout: timeout)
            return BridgeRouteProbeResult(ok: url.host == "bridge.example.com", latencyMs: 7)
        }

        let status = await resolver.resolve(
            localBridgeURLs: ["192.168.1.8:18081"],
            cloudBridgeURL: "bridge.example.com",
            token: " token "
        )
        let records = await log.records

        #expect(status.activeKind == .cloud)
        #expect(records.contains(ProbeRecord(url: "http://192.168.1.8:18081", token: "token", timeout: 0.75)))
        #expect(records.contains(ProbeRecord(url: "https://bridge.example.com", token: "token", timeout: 3.0)))
    }

    @Test func iOSPolicyKeepsSequentialLocalThenCloudChecks() async {
        let log = ProbeLog()
        let resolver = BridgeRouteResolutionCore(policy: .iOSClient) { url, token, timeout in
            await log.record(url: url.absoluteString, token: token, timeout: timeout)
            return BridgeRouteProbeResult(ok: url.host == "bridge.example.com", latencyMs: 9)
        }

        let status = await resolver.resolve(
            localBridgeURLs: ["192.168.1.8:18081"],
            cloudBridgeURL: "bridge.example.com",
            token: " token "
        )
        let records = await log.records

        #expect(status.activeKind == .cloud)
        #expect(records == [
            ProbeRecord(url: "http://192.168.1.8:18081", token: "token", timeout: 1.5),
            ProbeRecord(url: "https://bridge.example.com", token: "token", timeout: 3.0),
        ])
    }

    @Test func returnsUnavailableWithoutConfiguredURLs() async {
        let resolver = BridgeRouteResolutionCore(policy: .macClient) { _, _, _ in
            Issue.record("Probe should not run without URLs")
            return BridgeRouteProbeResult(ok: true, latencyMs: 1)
        }

        let status = await resolver.resolve(
            localBridgeURLs: [],
            cloudBridgeURL: "",
            token: "token"
        )

        #expect(status.activeKind == .unavailable)
        #expect(status.activeURL == nil)
        #expect(!status.localChecked)
        #expect(!status.cloudChecked)
        #expect(status.message == "Unavailable")
    }
}

@Suite("BridgeSettingsNormalization")
struct BridgeSettingsNormalizationTests {
    @Test func clampsSharedTimeoutRanges() {
        #expect(BridgeSettingsNormalization.clampedASRTimeoutSec(1) == 5)
        #expect(BridgeSettingsNormalization.clampedASRTimeoutSec(400) == 60)
        #expect(BridgeSettingsNormalization.correctionTimeoutMs(fromSeconds: 0.01) == 100)
        #expect(BridgeSettingsNormalization.correctionColdTimeoutMs(fromSeconds: 90) == 60_000)
    }

    @Test func normalizesModelIDsAgainstOptionsAndDefaults() {
        let options = [
            "qwen": [
                BridgeSettingOption(id: "default", displayName: "Default"),
                BridgeSettingOption(id: "large", displayName: "Large"),
            ],
            "apple": [],
        ]

        let normalized = BridgeSettingsNormalization.normalizedASRModelIDs(
            currentModelIDs: ["qwen": "default", "apple": "system"],
            incomingModelIDs: ["qwen": "missing", "apple": "system"],
            optionsBySource: options,
            defaultID: { sourceID in sourceID == "qwen" ? "large" : "" }
        )

        #expect(normalized["qwen"] == "large")
        #expect(normalized["apple"] == nil)
    }

    @Test func normalizesRimeUserPhrases() {
        let phrases = BridgeSettingsNormalization.rimeUserPhrases(
            from: ["  Hello   World ", "hello world", "", "Typeforme"]
        )

        #expect(phrases == ["Hello World", "Typeforme"])
    }

    @Test func ordersKnownLanguagesBeforeUnknownLanguages() {
        let options = BridgeSettingsNormalization.orderedUniqueLanguageOptions([
            BridgeLanguageOption(id: "zz", displayName: "Zulu Custom"),
            BridgeLanguageOption(id: "en-US", displayName: "English"),
            BridgeLanguageOption(id: "zh-CN", displayName: "Chinese"),
            BridgeLanguageOption(id: "en-US", displayName: "Duplicate English"),
        ])

        #expect(options.map(\.id) == ["zh-CN", "en-US", "zz"])
        #expect(options.first(where: { $0.id == "en-US" })?.displayName == "English")
    }
}

private struct ProbeRecord: Sendable, Equatable {
    let url: String
    let token: String
    let timeout: TimeInterval
}

private actor ProbeLog {
    private var storedRecords: [ProbeRecord] = []

    var records: [ProbeRecord] {
        storedRecords
    }

    func record(url: String, token: String, timeout: TimeInterval) {
        storedRecords.append(ProbeRecord(url: url, token: token, timeout: timeout))
    }
}
