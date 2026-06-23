import Foundation
import Testing
@testable import Typeforme

@Suite("BridgePairingPayload")
struct BridgePairingPayloadTests {
    @Test func pairingJSONOnlyContainsEnabledRoutesAndToken() throws {
        let payload = BridgePairingPayload(
            lanBridgeURL: " 192.168.1.10:18081 ",
            lanBridgeURLs: [
                "http://192.168.1.10:18081",
                " 10.0.0.5:18081 ",
            ],
            publicBridgeURL: "voice.example.com",
            token: " token-123 "
        )
        let data = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["lan_bridge_url", "lan_bridge_urls", "public_bridge_url", "token"])
        #expect(object["lan_bridge_url"] as? String == "http://192.168.1.10:18081")
        #expect(object["lan_bridge_urls"] as? [String] == [
            "http://192.168.1.10:18081",
            "http://10.0.0.5:18081",
        ])
        #expect(object["public_bridge_url"] as? String == "https://voice.example.com")
        #expect(object["token"] as? String == "token-123")
    }

    @Test func pairingJSONOmitsDisabledRoutes() throws {
        let payload = BridgePairingPayload(
            lanBridgeURL: nil,
            publicBridgeURL: "https://voice.example.com",
            token: "token-123"
        )
        let data = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["public_bridge_url", "token"])
        #expect(object["public_bridge_url"] as? String == "https://voice.example.com")
        #expect(object["token"] as? String == "token-123")
    }

    @Test func pairingJSONDecodeNormalizesRoutes() throws {
        let data = Data(
            """
            {
              "lan_bridge_url": " 192.168.1.10:18081 ",
              "lan_bridge_urls": ["http://192.168.1.10:18081", "10.0.0.5:18081"],
              "public_bridge_url": "voice.example.com",
              "token": " token-123 "
            }
            """.utf8
        )

        let payload = try BridgeJSON.decode(BridgePairingPayload.self, from: data)

        #expect(payload.lanBridgeURL == "http://192.168.1.10:18081")
        #expect(payload.lanBridgeURLs == [
            "http://192.168.1.10:18081",
            "http://10.0.0.5:18081",
        ])
        #expect(payload.publicBridgeURL == "https://voice.example.com")
        #expect(payload.token == "token-123")
    }

    @Test func pairingJSONRequiresTokenAndCurrentURLKeys() {
        let legacyOnly = Data(
            """
            {
              "bridge_url": "http://192.168.1.10:18081",
              "auth_token": "token-123"
            }
            """.utf8
        )
        let emptyToken = Data(
            """
            {
              "lan_bridge_url": "http://192.168.1.10:18081",
              "token": " "
            }
            """.utf8
        )
        let tokenOnly = Data(
            """
            {
              "token": "token-123"
            }
            """.utf8
        )

        #expect(throws: (any Error).self) {
            try BridgeJSON.decode(BridgePairingPayload.self, from: legacyOnly)
        }
        #expect(throws: (any Error).self) {
            try BridgeJSON.decode(BridgePairingPayload.self, from: emptyToken)
        }
        #expect(throws: (any Error).self) {
            try BridgeJSON.decode(BridgePairingPayload.self, from: tokenOnly)
        }
    }

    @Test func pairingPayloadFeedsClientConfiguration() throws {
        let payload = try BridgeJSON.decode(
            BridgePairingPayload.self,
            from: Data(
                """
                {
                  "lan_bridge_url": "192.168.1.10:18081",
                  "lan_bridge_urls": ["http://192.168.1.10:18081", "10.0.0.5:18081"],
                  "public_bridge_url": "voice.example.com",
                  "token": " token-123 "
                }
                """.utf8
            )
        )

        let config = ClientBridgeConfiguration.fromPairingPayload(payload)

        #expect(config.localBridgeURLs == [
            "http://192.168.1.10:18081",
            "http://10.0.0.5:18081",
        ])
        #expect(config.cloudBridgeURL == "https://voice.example.com")
        #expect(config.token == "token-123")
    }
}
