import Foundation

enum KeyboardRimeCompositionPolicy {
    static func targetIsCurrent(
        capturedDocumentIdentifier: UUID,
        currentDocumentIdentifier: UUID
    ) -> Bool {
        capturedDocumentIdentifier == currentDocumentIdentifier
    }
}

enum KeyboardRimeInlineEditPolicy {
    static func supports(rawInput: String, preedit: String) -> Bool {
        !rawInput.isEmpty
            && rawInput.unicodeScalars.allSatisfy(\.isASCII)
            && preedit.unicodeScalars.allSatisfy(\.isASCII)
    }

    static func clampedCaretOffset(_ offset: Int, in rawInput: String) -> Int {
        min(max(offset, 0), rawInput.utf8.count)
    }

    static func inserting(_ text: String, in rawInput: String, at offset: Int) -> String? {
        guard text.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        var bytes = Array(rawInput.utf8)
        bytes.insert(contentsOf: text.utf8, at: clampedCaretOffset(offset, in: rawInput))
        return String(decoding: bytes, as: UTF8.self)
    }

    static func deletingCharacter(before offset: Int, in rawInput: String) -> String? {
        let caretOffset = clampedCaretOffset(offset, in: rawInput)
        guard caretOffset > 0 else { return nil }
        var bytes = Array(rawInput.utf8)
        bytes.remove(at: caretOffset - 1)
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum KeyboardLivePartialOwnershipPolicy {
    static func insertionTargetIsCurrent(
        capturedDocumentIdentifier: UUID,
        currentDocumentIdentifier: UUID,
        capturedContextBefore: String,
        capturedContextAfter: String,
        currentContextBefore: String,
        currentContextAfter: String
    ) -> Bool {
        capturedDocumentIdentifier == currentDocumentIdentifier
            && capturedContextBefore == currentContextBefore
            && capturedContextAfter == currentContextAfter
    }

    static func ownsMarkedText(
        expectedCommandID: String,
        commandID: String,
        expectedDocumentIdentifier: UUID,
        documentIdentifier: UUID,
        expectedText: String,
        activeMarkedText: String,
        hasLivePartialOwner: Bool
    ) -> Bool {
        hasLivePartialOwner
            && !expectedText.isEmpty
            && expectedCommandID == commandID
            && expectedDocumentIdentifier == documentIdentifier
            && expectedText == activeMarkedText
    }
}
