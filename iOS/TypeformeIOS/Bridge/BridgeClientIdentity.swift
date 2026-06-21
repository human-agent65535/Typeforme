import Foundation
import os.lock

enum BridgeClientIdentityHeaders {
    static let id = "X-Typeforme-Client-ID"
    static let name = "X-Typeforme-Client-Name"
    static let platform = "X-Typeforme-Client-Platform"
    static let bundleID = "X-Typeforme-Client-Bundle-ID"
}

enum BridgeClientIdentity {
    private static let identityKey = "bridge.clientIdentityID.v1"
    private static let cachedIdentityID = OSAllocatedUnfairLock<String?>(initialState: nil)

    static func apply(to request: inout URLRequest) {
        request.setValue(identityID, forHTTPHeaderField: BridgeClientIdentityHeaders.id)
        request.setValue("Typeforme iOS", forHTTPHeaderField: BridgeClientIdentityHeaders.name)
        request.setValue("iOS", forHTTPHeaderField: BridgeClientIdentityHeaders.platform)
        request.setValue(
            Bundle.main.bundleIdentifier ?? TypeformeBundleConfiguration.hostBundleIdentifier,
            forHTTPHeaderField: BridgeClientIdentityHeaders.bundleID
        )
    }

    private static var identityID: String {
        cachedIdentityID.withLock { cachedIdentityID in
            if let cached = clean(cachedIdentityID) {
                return cached
            }
            if let existing = clean(UserDefaults.standard.string(forKey: identityKey)) {
                cachedIdentityID = existing
                return existing
            }
            let identity = "ios-\(UUID().uuidString.lowercased())"
            UserDefaults.standard.set(identity, forKey: identityKey)
            cachedIdentityID = identity
            return identity
        }
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
