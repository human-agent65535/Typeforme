import Foundation
import Testing
@testable import Typeforme

@Suite("BridgeConnectionStore")
struct BridgeConnectionStoreTests {
    @Test func aggregatesRequestsByClientAndEndpoint() {
        var accumulator = BridgeConnectionAccumulator()
        let now = Date(timeIntervalSince1970: 1_000)

        _ = accumulator.record(
            BridgeClientRequestActivity(
                endpoint: .health,
                clientHost: "192.168.1.20",
                clientPort: 52000,
                userAgent: nil,
                clientIdentityID: "ios-1111",
                statusCode: 200,
                occurredAt: now,
                latencyMs: 12,
                appName: nil,
                bundleID: nil,
                clientDisplayName: "Typeforme iOS"
            )
        )

        let snapshot = accumulator.record(
            BridgeClientRequestActivity(
                endpoint: .dictate,
                clientHost: "192.168.1.20",
                clientPort: 52010,
                userAgent: "Typeforme iOS",
                clientIdentityID: "ios-1111",
                statusCode: 400,
                occurredAt: now.addingTimeInterval(2),
                latencyMs: 34,
                appName: "iOS",
                bundleID: "com.example.typeforme",
                clientDisplayName: "Typeforme iOS"
            )
        )

        #expect(snapshot.clients.count == 1)
        #expect(snapshot.totalRequests == 2)
        #expect(snapshot.successfulRequests == 1)
        #expect(snapshot.failedRequests == 1)
        #expect(snapshot.count(for: .health) == 1)
        #expect(snapshot.count(for: .dictate) == 1)

        let client = snapshot.clients[0]
        #expect(client.id == "ios-1111")
        #expect(client.host == "192.168.1.20")
        #expect(client.clientDisplayName == "Typeforme iOS")
        #expect(client.lastPort == 52010)
        #expect(client.userAgent == "Typeforme iOS")
        #expect(client.appName == "iOS")
        #expect(client.bundleID == "com.example.typeforme")
        #expect(client.requestCount == 2)
        #expect(client.successCount == 1)
        #expect(client.failureCount == 1)
        #expect(client.lastEndpoint == .dictate)
        #expect(client.lastStatusCode == 400)
        #expect(client.count(for: .health) == 1)
    }

    @Test func resetClearsSnapshot() {
        var accumulator = BridgeConnectionAccumulator()
        _ = accumulator.record(
            BridgeClientRequestActivity(
                endpoint: .settingsRead,
                clientHost: "10.0.0.5",
                clientPort: 51000,
                userAgent: nil,
                clientIdentityID: "mac-2222",
                statusCode: 200,
                occurredAt: Date(timeIntervalSince1970: 2_000),
                latencyMs: 4,
                appName: nil,
                bundleID: nil
            )
        )

        let snapshot = accumulator.reset()

        #expect(snapshot.clients.isEmpty)
        #expect(snapshot.totalRequests == 0)
        #expect(snapshot.lastRequestAt == nil)
    }

    @Test func stableClientIdentityAggregatesAcrossRoutes() {
        var accumulator = BridgeConnectionAccumulator()
        let now = Date(timeIntervalSince1970: 3_000)

        _ = accumulator.record(
            BridgeClientRequestActivity(
                endpoint: .health,
                clientHost: "127.0.0.1",
                clientPort: 52000,
                userAgent: nil,
                clientIdentityID: "ios-1111",
                statusCode: 200,
                occurredAt: now,
                latencyMs: 1,
                appName: nil,
                bundleID: nil,
                clientDisplayName: "Typeforme iOS",
                clientPlatform: "iOS",
                clientBundleID: "com.example.typeforme"
            )
        )

        let snapshot = accumulator.record(
            BridgeClientRequestActivity(
                endpoint: .settingsRead,
                clientHost: "198.51.100.20",
                clientPort: 443,
                userAgent: nil,
                clientIdentityID: "ios-1111",
                statusCode: 200,
                occurredAt: now.addingTimeInterval(5),
                latencyMs: 2,
                appName: nil,
                bundleID: nil,
                clientDisplayName: "Typeforme iOS",
                clientPlatform: "iOS",
                clientBundleID: "com.example.typeforme",
                forwardedClientIP: "203.0.113.44",
                cloudflareRayID: "abc-NRT"
            )
        )

        #expect(snapshot.clients.count == 1)
        let client = snapshot.clients[0]
        #expect(client.id == "ios-1111")
        #expect(client.host == "198.51.100.20")
        #expect(client.clientDisplayName == "Typeforme iOS")
        #expect(client.clientBundleID == "com.example.typeforme")
        #expect(client.forwardedClientIP == "203.0.113.44")
        #expect(client.usesCloudflare)
        #expect(client.requestCount == 2)
        #expect(client.count(for: .health) == 1)
        #expect(client.count(for: .settingsRead) == 1)
    }

}
