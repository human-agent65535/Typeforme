import Foundation
import Testing
@testable import Typeforme

@Suite("BridgeHTTPServer", .serialized)
struct BridgeHTTPServerTests {
    @Test @MainActor func unexpectedListenerExitPublishesFailureAndCanBeStoppedCleanly() async {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-bridge-listener-exit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let settings = ControlledBridgeListenerSettings(
            BridgeListenerConfiguration(enabled: true, host: "127.0.0.1", port: 18_091)
        )
        let runner = ControlledBridgeListenerRunner()
        let server = BridgeHTTPServer(
            dictionary: UserDictionaryStore(url: dictionaryURL),
            listenerRunOperation: { host, port in
                await runner.run(host: host, port: port)
            },
            listenerConfigurationProvider: {
                settings.current
            }
        )

        server.applySettings()
        await runner.waitUntilStartCount(1)
        await runner.allowRunToReturn(0)
        while BridgeServerStatusStore.shared.status == .running(host: "127.0.0.1", port: 18_091) {
            await Task.yield()
        }
        #expect(BridgeServerStatusStore.shared.status == .failed(
            message: "Bridge listener stopped unexpectedly"
        ))
        await server.stop().value
    }

    @Test @MainActor func restartWaitsForPreviousListenerAndLatestReservationWins() async {
        let dictionaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeforme-bridge-listener-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }
        let settings = ControlledBridgeListenerSettings(
            BridgeListenerConfiguration(enabled: true, host: "127.0.0.1", port: 18_081)
        )
        let runner = ControlledBridgeListenerRunner()
        let server = BridgeHTTPServer(
            dictionary: UserDictionaryStore(url: dictionaryURL),
            listenerRunOperation: { host, port in
                await runner.run(host: host, port: port)
            },
            listenerConfigurationProvider: {
                settings.current
            }
        )

        server.applySettings()
        server.applySettings()
        await runner.waitUntilStartCount(1)
        #expect(await runner.startedPorts == [18_081])
        #expect(await runner.maximumConcurrentRunCount == 1)

        settings.update(port: 18_082)
        server.applySettings()
        settings.update(port: 18_083)
        server.applySettings()
        await runner.waitUntilCancellationCount(1)

        // Cancellation alone does not release this deterministic fake. No
        // successor may bind until the old listener has actually returned.
        #expect(await runner.startedPorts == [18_081])
        #expect(await runner.activeRunCount == 1)

        await runner.allowRunToReturn(0)
        await runner.waitUntilStartCount(2)
        #expect(await runner.startedPorts == [18_081, 18_083])
        #expect(await runner.maximumConcurrentRunCount == 1)

        server.applySettings()
        server.applySettings()
        await Task.yield()
        #expect(await runner.startedPorts == [18_081, 18_083])

        let stopBarrier = server.stop()
        await runner.waitUntilCancellationCount(2)
        #expect(await runner.activeRunCount == 1)
        await runner.allowRunToReturn(1)
        await stopBarrier.value
        #expect(await runner.activeRunCount == 0)
    }

    @Test func trustsForwardedHeadersFromLANOnlyWhenLANAccessIsEnabled() {
        #expect(!BridgeHTTPServer.shouldTrustForwardedHeaders(
            remoteIP: "192.168.50.111",
            publicBridgeEnabled: true,
            lanBridgeEnabled: false
        ))
        #expect(BridgeHTTPServer.shouldTrustForwardedHeaders(
            remoteIP: "192.168.50.111",
            publicBridgeEnabled: true,
            lanBridgeEnabled: true
        ))
    }

    @Test func requiresPublicBridgeBeforeTrustingForwardedHeaders() {
        #expect(!BridgeHTTPServer.shouldTrustForwardedHeaders(
            remoteIP: "127.0.0.1",
            publicBridgeEnabled: false,
            lanBridgeEnabled: true
        ))
        #expect(!BridgeHTTPServer.shouldTrustForwardedHeaders(
            remoteIP: "192.168.50.111",
            publicBridgeEnabled: false,
            lanBridgeEnabled: true
        ))
    }

    @Test func stillTrustsLocalhostTunnelWithoutLANAccess() {
        #expect(BridgeHTTPServer.shouldTrustForwardedHeaders(
            remoteIP: "127.0.0.1",
            publicBridgeEnabled: true,
            lanBridgeEnabled: false
        ))
        #expect(BridgeHTTPServer.shouldTrustForwardedHeaders(
            remoteIP: "::1",
            publicBridgeEnabled: true,
            lanBridgeEnabled: false
        ))
    }

    @Test func doesNotTrustPublicRemoteAddresses() {
        #expect(!BridgeHTTPServer.shouldTrustForwardedHeaders(
            remoteIP: "198.51.100.20",
            publicBridgeEnabled: true,
            lanBridgeEnabled: true
        ))
        #expect(!BridgeHTTPServer.shouldTrustForwardedHeaders(
            remoteIP: nil,
            publicBridgeEnabled: true,
            lanBridgeEnabled: true
        ))
    }

    @Test func recognizesPrivateIPv4LANRanges() {
        #expect(BridgeHTTPServer.shouldTrustForwardedHeaders(
            remoteIP: "10.0.0.5",
            publicBridgeEnabled: true,
            lanBridgeEnabled: true
        ))
        #expect(BridgeHTTPServer.shouldTrustForwardedHeaders(
            remoteIP: "172.16.0.2",
            publicBridgeEnabled: true,
            lanBridgeEnabled: true
        ))
        #expect(BridgeHTTPServer.shouldTrustForwardedHeaders(
            remoteIP: "172.31.255.254",
            publicBridgeEnabled: true,
            lanBridgeEnabled: true
        ))
        #expect(!BridgeHTTPServer.shouldTrustForwardedHeaders(
            remoteIP: "172.32.0.1",
            publicBridgeEnabled: true,
            lanBridgeEnabled: true
        ))
    }
}

private final class ControlledBridgeListenerSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: BridgeListenerConfiguration

    init(_ configuration: BridgeListenerConfiguration) {
        self.configuration = configuration
    }

    var current: BridgeListenerConfiguration {
        lock.withLock { configuration }
    }

    func update(port: Int) {
        lock.withLock {
            configuration = BridgeListenerConfiguration(
                enabled: configuration.enabled,
                host: configuration.host,
                port: port
            )
        }
    }
}

private actor ControlledBridgeListenerRunner {
    private var ports: [Int] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var cancelledRunIDs: Set<Int> = []
    private var activeCount = 0
    private var maximumActiveCount = 0

    var startedPorts: [Int] { ports }
    var activeRunCount: Int { activeCount }
    var maximumConcurrentRunCount: Int { maximumActiveCount }

    func run(host: String, port: Int) async {
        let runID = ports.count
        ports.append(port)
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations[runID] = continuation
            }
        } onCancel: {
            Task {
                await self.recordCancellation(runID)
            }
        }
        activeCount -= 1
    }

    func allowRunToReturn(_ runID: Int) {
        continuations.removeValue(forKey: runID)?.resume()
    }

    func waitUntilStartCount(_ expected: Int) async {
        while ports.count < expected {
            await Task.yield()
        }
    }

    func waitUntilCancellationCount(_ expected: Int) async {
        while cancelledRunIDs.count < expected {
            await Task.yield()
        }
    }

    private func recordCancellation(_ runID: Int) {
        cancelledRunIDs.insert(runID)
    }
}
