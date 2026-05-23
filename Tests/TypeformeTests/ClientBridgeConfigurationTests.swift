import Testing
@testable import Typeforme

@Suite("ClientBridgeConfiguration")
struct ClientBridgeConfigurationTests {
    @Test func publicHostWithPortDefaultsToHTTPS() {
        #expect(ClientBridgeConfiguration.normalizedBaseURL("voice.example.com:443") == "https://voice.example.com:443")
        #expect(ClientBridgeConfiguration.normalizedBaseURL("voice.example.com:18081") == "https://voice.example.com:18081")
    }

    @Test func localHostsDefaultToHTTP() {
        #expect(ClientBridgeConfiguration.normalizedBaseURL("localhost:18081") == "http://localhost:18081")
        #expect(ClientBridgeConfiguration.normalizedBaseURL("127.0.0.1:18081") == "http://127.0.0.1:18081")
        #expect(ClientBridgeConfiguration.normalizedBaseURL("192.168.1.9:18081") == "http://192.168.1.9:18081")
        #expect(ClientBridgeConfiguration.normalizedBaseURL("10.0.0.9:18081") == "http://10.0.0.9:18081")
        #expect(ClientBridgeConfiguration.normalizedBaseURL("172.20.0.9:18081") == "http://172.20.0.9:18081")
        #expect(ClientBridgeConfiguration.normalizedBaseURL("[::1]:18081") == "http://[::1]:18081")
    }
}
