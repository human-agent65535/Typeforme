import Foundation
import Security

enum PairingStoreError: LocalizedError {
    case encodeFailed
    case secureTokenWriteFailed

    var errorDescription: String? {
        switch self {
        case .encodeFailed:
            return "Pairing details could not be encoded."
        case .secureTokenWriteFailed:
            return "The pairing token could not be saved securely."
        }
    }
}

struct PairingStore {
    private let key = "pairing.config.v1"

    func load() -> PairingConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              var config = try? JSONDecoder().decode(PairingConfig.self, from: data)
        else {
            return .empty
        }

        config.normalize()
        config.token = PairingTokenStore.macBridge.load() ?? ""
        return config
    }

    /// Publishes matching endpoints only after Keychain reports a successful
    /// token write. This prevents an explicit Keychain failure from producing
    /// a mixed tuple; the two system stores do not provide a shared transaction.
    func save(_ config: PairingConfig) throws {
        var persisted = config
        persisted.normalize()
        let token = persisted.token.trimmingCharacters(in: .whitespacesAndNewlines)
        persisted.token = ""

        guard let data = try? JSONEncoder().encode(persisted) else {
            throw PairingStoreError.encodeFailed
        }
        let tokenStore = PairingTokenStore.macBridge
        if tokenStore.load() != token,
           !tokenStore.save(token) {
            throw PairingStoreError.secureTokenWriteFailed
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    func delete() {
        UserDefaults.standard.removeObject(forKey: key)
        PairingTokenStore.macBridge.delete()
    }
}

struct PairingTokenStore {
    static let macBridge = PairingTokenStore(
        service: TypeformeBundleConfiguration.hostBundleIdentifier,
        account: "mac-bridge-token"
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

    @discardableResult
    func save(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return delete()
        }

        let data = Data(trimmed.utf8)
        var query = baseQuery(service: service)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func delete() -> Bool {
        let status = SecItemDelete(baseQuery(service: service) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
