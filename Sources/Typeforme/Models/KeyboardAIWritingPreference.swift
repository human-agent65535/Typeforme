import Foundation

/// Host defaults acknowledge a particular mode request. Keeping the request
/// separate lets the keyboard switch while the host is suspended, without an
/// older defaults publication undoing a newer press.
struct KeyboardAIWritingPreference: Equatable, Sendable {
    struct Request: Codable, Equatable, Sendable {
        let id: String
        let enabled: Bool

        init(enabled: Bool, id: String = UUID().uuidString) {
            self.id = id
            self.enabled = enabled
        }
    }

    let enabled: Bool
    var appliedRequestID: String? = nil

    func applying(_ request: Request?) -> Self {
        guard let request, request.id != appliedRequestID else { return self }
        return Self(enabled: request.enabled, appliedRequestID: request.id)
    }
}
