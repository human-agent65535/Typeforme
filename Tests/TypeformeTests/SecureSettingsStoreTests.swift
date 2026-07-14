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

    @Test func ensureReturnsExistingValueWithoutWriting() throws {
        let store = MemorySecureSettingsStore(values: ["bridge.authToken": "saved-token"], failWrites: true)
        let value = SecureSettingValue(key: "bridge.authToken", store: store)

        #expect(try value.ensure(generating: { "new-token" }) == "saved-token")
    }

    @Test func ensureAndReplacePropagateSecureWriteFailure() {
        let store = MemorySecureSettingsStore(failWrites: true)
        let value = SecureSettingValue(key: "bridge.authToken", store: store)

        #expect(throws: SecureSettingError.self) {
            try value.ensure(generating: { "new-token" })
        }
        #expect(throws: SecureSettingError.self) {
            try value.replace(with: "rotated-token")
        }
        #expect(store.values["bridge.authToken"] == nil)
    }

    @Test func replaceRequiresSecureStoreReadback() {
        let store = MemorySecureSettingsStore(failReads: true)
        let value = SecureSettingValue(key: "bridge.authToken", store: store)

        #expect(throws: SecureSettingError.self) {
            try value.replace(with: "rotated-token")
        }
    }

    @Test func throwingSetPreservesExistingValueWhenReplacementFails() {
        let store = MemorySecureSettingsStore(
            values: ["processing.client.bridgeToken": "current-token"],
            failWrites: true
        )
        let value = SecureSettingValue(key: "processing.client.bridgeToken", store: store)

        #expect(throws: SecureSettingError.self) {
            try value.set("replacement-token")
        }
        #expect(store.values["processing.client.bridgeToken"] == "current-token")
    }

    @Test func throwingSetPreservesExistingValueWhenRevocationFails() {
        let store = MemorySecureSettingsStore(
            values: ["processing.client.bridgeToken": "current-token"],
            failRemovals: true
        )
        let value = SecureSettingValue(key: "processing.client.bridgeToken", store: store)

        #expect(throws: SecureSettingError.self) {
            try value.set("  ")
        }
        #expect(store.values["processing.client.bridgeToken"] == "current-token")
    }

    @Test func throwingSetReturnsCanonicalPersistedValue() throws {
        let store = MemorySecureSettingsStore()
        let value = SecureSettingValue(key: "correction.externalLLMAPIKey", store: store)

        #expect(try value.set(" api-key ") == "api-key")
        #expect(try value.set(" ") == "")
        #expect(store.values["correction.externalLLMAPIKey"] == nil)
    }
}

private final class MemorySecureSettingsStore: SecureSettingsStoring, @unchecked Sendable {
    var values: [String: String]
    var failWrites: Bool
    var failReads: Bool
    var failRemovals: Bool

    init(
        values: [String: String] = [:],
        failWrites: Bool = false,
        failReads: Bool = false,
        failRemovals: Bool = false
    ) {
        self.values = values
        self.failWrites = failWrites
        self.failReads = failReads
        self.failRemovals = failRemovals
    }

    func string(forKey key: String) -> String? {
        guard !failReads else { return nil }
        return values[key]
    }

    func setString(_ value: String, forKey key: String) -> Bool {
        guard !failWrites else { return false }
        values[key] = value
        return true
    }

    func removeString(forKey key: String) -> Bool {
        guard !failWrites, !failRemovals else { return false }
        values.removeValue(forKey: key)
        return true
    }
}
