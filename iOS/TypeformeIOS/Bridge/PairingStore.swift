import Foundation
import Security

struct PairingStore {
    private let key = "pairing.config.v1"
    // One-time migration for installs that still have the Mac pairing token in
    // Keychain. Input: Generic Password services "com.example.typeforme" and
    // "com.typeforme.ios.bridge", account "pairing-token". Output: write the
    // token into UserDefaults key "pairing.config.v1" as
    // bridge_endpoints.token, then delete the Keychain item. Code location:
    // PairingStore.load(). Removal date: 2026-06-30.
    private let keychainMigrationStores = [
        PairingTokenStore.bridgePairing,
        PairingTokenStore.legacyBridgePairing,
    ]

    func load() -> PairingConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              var config = try? JSONDecoder().decode(PairingConfig.self, from: data)
        else {
            return .empty
        }

        let persistedToken = config.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !persistedToken.isEmpty {
            config.token = persistedToken
            return config
        }

        if let migratedToken = keychainMigrationStores.lazy.compactMap({ $0.load() }).first {
            config.token = migratedToken
            if persistConfig(config) { deleteKeychainMigrationTokens() }
        }

        return config
    }

    func save(_ config: PairingConfig) {
        var persisted = config
        persisted.token = persisted.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if persistConfig(persisted) { deleteKeychainMigrationTokens() }
    }

    func delete() {
        deleteKeychainMigrationTokens()
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func persistConfig(_ config: PairingConfig) -> Bool {
        guard let data = try? JSONEncoder().encode(config) else { return false }
        UserDefaults.standard.set(data, forKey: key)
        return UserDefaults.standard.synchronize()
    }

    private func deleteKeychainMigrationTokens() {
        for store in keychainMigrationStores {
            store.delete()
        }
    }
}

struct PairingTokenStore {
    static let bridgePairing = PairingTokenStore(
        service: "com.example.typeforme",
        account: "pairing-token"
    )
    static let keyboardBridge = PairingTokenStore(
        service: "com.example.typeforme.keyboard",
        account: "keyboard-bridge-token"
    )
    fileprivate static let legacyBridgePairing = PairingTokenStore(
        service: "com.typeforme.ios.bridge",
        account: "pairing-token"
    )

    private let service: String
    private let account: String

    func load() -> String? {
        load(service: service)
    }

    private func load(service: String) -> String? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func save(_ token: String) {
        let data = Data(token.utf8)
        var query = baseQuery(service: service)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
            NSLog("Typeforme PairingTokenStore save failed: \(addStatus)")
        }
    }

    func delete() {
        let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("Typeforme PairingTokenStore delete failed: \(status)")
        }
    }

    private func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
