import Foundation

enum BridgeClientIdentity {
    static func apply(to request: inout URLRequest) {
        request.setValue(AppSettings.clientIdentityID, forHTTPHeaderField: BridgeClientIdentityHeaders.id)
        request.setValue("Typeforme Mac", forHTTPHeaderField: BridgeClientIdentityHeaders.name)
        request.setValue("macOS", forHTTPHeaderField: BridgeClientIdentityHeaders.platform)
        request.setValue(
            BundleIdentity.mainBundleIdentifier,
            forHTTPHeaderField: BridgeClientIdentityHeaders.bundleID
        )
    }
}
