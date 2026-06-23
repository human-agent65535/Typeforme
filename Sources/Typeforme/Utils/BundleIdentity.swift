import Foundation

enum BundleIdentity {
    static var mainBundleIdentifier: String {
        guard let identifier = Bundle.main.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !identifier.isEmpty
        else {
            preconditionFailure("Typeforme requires CFBundleIdentifier at runtime")
        }
        return identifier
    }
}
