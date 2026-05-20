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

    static func apply(to request: inout URLRequest) {
        request.setValue(identityID, forHTTPHeaderField: BridgeClientIdentityHeaders.id)
        request.setValue("Typeforme iOS", forHTTPHeaderField: BridgeClientIdentityHeaders.name)
        request.setValue(UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS", forHTTPHeaderField: BridgeClientIdentityHeaders.platform)
        request.setValue(
            Bundle.main.bundleIdentifier ?? "com.example.typeforme",
            forHTTPHeaderField: BridgeClientIdentityHeaders.bundleID
        )
    }

    private static var identityID: String {
        if let existing = UserDefaults.standard.string(forKey: identityKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let identity = "ios-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(identity, forKey: identityKey)
        return identity
    }
}
