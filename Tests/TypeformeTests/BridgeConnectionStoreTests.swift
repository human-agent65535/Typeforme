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
                statusCode: 200,
                occurredAt: now,
                latencyMs: 12,
                appName: nil,
                bundleID: nil
            )
        )

        let snapshot = accumulator.record(
            BridgeClientRequestActivity(
                endpoint: .dictate,
                clientHost: "192.168.1.20",
                clientPort: 52010,
                userAgent: "Typeforme iOS",
                statusCode: 400,
                occurredAt: now.addingTimeInterval(2),
                latencyMs: 34,
                appName: "iOS",
                bundleID: "com.example.typeforme"
            )
        )

        #expect(snapshot.clients.count == 1)
        #expect(snapshot.totalRequests == 2)
        #expect(snapshot.successfulRequests == 1)
        #expect(snapshot.failedRequests == 1)
        #expect(snapshot.count(for: .health) == 1)
        #expect(snapshot.count(for: .dictate) == 1)

        let client = snapshot.clients[0]
        #expect(client.host == "192.168.1.20")
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
}
