import Foundation

/// AI Writing owns one captured input snapshot. Editing or leaving that input
/// invalidates the request even if identical text is subsequently retyped.
struct KeyboardPinyinConversionSession {
    struct Target: Equatable {
        let documentIdentifier: UUID
        let contextBefore: String?
        let selectedText: String?
        let contextAfter: String?
    }

    struct Request: Equatable {
        let id: String
        let target: Target
    }

    private(set) var request: Request?

    mutating func begin(target: Target) -> Request? {
        guard request == nil else { return nil }
        let next = Request(id: UUID().uuidString, target: target)
        request = next
        return next
    }

    mutating func cancel() {
        request = nil
    }

    mutating func takeResult(
        requestID: String,
        currentTarget: Target?,
        documentIsCurrent: Bool,
        isEnabled: Bool,
        isVisible: Bool
    ) -> Bool {
        guard let request, request.id == requestID else { return false }
        self.request = nil
        guard isEnabled, isVisible, documentIsCurrent,
              request.target == currentTarget
        else { return false }
        return true
    }
}
