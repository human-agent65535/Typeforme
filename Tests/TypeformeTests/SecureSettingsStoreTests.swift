import Foundation
import Testing
@testable import Typeforme

@Suite("SecureSettingsStore")
struct SecureSettingsStoreTests {
    @Test func loadsFromSecureStore() {
        let store = MemorySecureSettingsStore(values: ["bridge.authToken": "secure-token"])

        let value = SecureSettingValue(
            key: "bridge.authToken",
            store: store
        ).load()

        #expect(value == "secure-token")
    }

    @Test func returnsEmptyStringWhenSecureValueIsMissing() {
        let store = MemorySecureSettingsStore()

        let value = SecureSettingValue(
            key: "processing.client.bridgeToken",
            store: store
        ).load()

        #expect(value == "")
    }

    @Test func savesAndRemovesSecureValue() {
        let store = MemorySecureSettingsStore()
        let value = SecureSettingValue(
            key: "correction.externalLLMAPIKey",
            store: store
        )

        #expect(value.save(" api-key "))
        #expect(store.values["correction.externalLLMAPIKey"] == "api-key")

        #expect(value.save(" "))
        #expect(store.values["correction.externalLLMAPIKey"] == nil)
    }

    @Test func saveFailureDoesNotWriteSecureValue() {
        let store = MemorySecureSettingsStore(failWrites: true)
        let value = SecureSettingValue(
            key: "correction.externalLLMAPIKey",
            store: store
        )

        #expect(!value.save("api-key"))
        #expect(store.values["correction.externalLLMAPIKey"] == nil)
    }
}

private final class MemorySecureSettingsStore: SecureSettingsStoring, @unchecked Sendable {
    var values: [String: String]
    var failWrites: Bool

    init(values: [String: String] = [:], failWrites: Bool = false) {
        self.values = values
        self.failWrites = failWrites
    }

    func string(forKey key: String) -> String? {
        values[key]
    }

    func setString(_ value: String, forKey key: String) -> Bool {
        guard !failWrites else { return false }
        values[key] = value
        return true
    }

    func removeString(forKey key: String) -> Bool {
        guard !failWrites else { return false }
        values.removeValue(forKey: key)
        return true
    }
}
