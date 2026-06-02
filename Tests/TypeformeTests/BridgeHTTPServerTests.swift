import Testing
@testable import Typeforme

@Suite("BridgeHTTPServer")
struct BridgeHTTPServerTests {
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
