import Foundation

enum BridgeClientIdentityHeaders {
    static let id = "X-Typeforme-Client-ID"
    static let name = "X-Typeforme-Client-Name"
    static let platform = "X-Typeforme-Client-Platform"
    static let bundleID = "X-Typeforme-Client-Bundle-ID"
}

enum BridgeClientIdentity {
    static func apply(to request: inout URLRequest) {
        request.setValue(AppSettings.clientIdentityID, forHTTPHeaderField: BridgeClientIdentityHeaders.id)
        request.setValue("Typeforme Mac", forHTTPHeaderField: BridgeClientIdentityHeaders.name)
        request.setValue("macOS", forHTTPHeaderField: BridgeClientIdentityHeaders.platform)
        request.setValue(
            Bundle.main.bundleIdentifier ?? "com.example.typeforme.mac",
            forHTTPHeaderField: BridgeClientIdentityHeaders.bundleID
        )
    }
}
