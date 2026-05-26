import Foundation
import UIKit

enum BridgeClientIdentityHeaders {
    static let id = "X-Typeforme-Client-ID"
    static let name = "X-Typeforme-Client-Name"
    static let platform = "X-Typeforme-Client-Platform"
    static let bundleID = "X-Typeforme-Client-Bundle-ID"
}

enum BridgeClientIdentity {
    private static let identityKey = "bridge.clientIdentityID.v1"
    private static let identityLock = NSLock()
    private static var cachedIdentityID: String?

    static func apply(to request: inout URLRequest) {
        request.setValue(identityID, forHTTPHeaderField: BridgeClientIdentityHeaders.id)
        request.setValue("Typeforme iOS", forHTTPHeaderField: BridgeClientIdentityHeaders.name)
        request.setValue(
            UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS",
            forHTTPHeaderField: BridgeClientIdentityHeaders.platform
        )
        request.setValue(
            Bundle.main.bundleIdentifier ?? TypeformeBundleConfiguration.hostBundleIdentifier,
            forHTTPHeaderField: BridgeClientIdentityHeaders.bundleID
        )
    }

    private static var identityID: String {
        identityLock.lock()
        defer { identityLock.unlock() }

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

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
