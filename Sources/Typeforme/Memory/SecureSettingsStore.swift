import Foundation
import Security

protocol SecureSettingsStoring: Sendable {
    func string(forKey key: String) -> String?
    @discardableResult func setString(_ value: String, forKey key: String) -> Bool
    @discardableResult func removeString(forKey key: String) -> Bool
}

struct KeychainSecureSettingsStore: SecureSettingsStoring {
    let service: String

    init(service: String = "\(BundleIdentity.mainBundleIdentifier).secure-settings") {
        self.service = service
    }

    func string(forKey key: String) -> String? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    func setString(_ value: String, forKey key: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return removeString(forKey: key)
        }

        let data = Data(trimmed.utf8)
        let query = baseQuery(forKey: key)
        let update: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func removeString(forKey key: String) -> Bool {
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

struct SecureSettingValue {
    let key: String
    let store: SecureSettingsStoring

    func load() -> String {
        store.string(forKey: key) ?? ""
    }

    @discardableResult
    func save(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return store.removeString(forKey: key)
        }

        return store.setString(trimmed, forKey: key)
    }
}
