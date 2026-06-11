import Foundation

/// Published truth about the Bridge listener. The `bridgeEnabled` setting
/// records intent; this records what actually happened on the socket, so the
/// Settings UI can show a bind failure (port in use, permission) instead of
/// a green "Enabled" that lies.
@MainActor
final class BridgeServerStatusStore: ObservableObject {
    static let shared = BridgeServerStatusStore()

    enum Status: Equatable {
        case stopped
        case running(host: String, port: Int)
        case failed(message: String)
    }

    @Published private(set) var status: Status = .stopped

    func set(_ status: Status) {
        self.status = status
    }
}
