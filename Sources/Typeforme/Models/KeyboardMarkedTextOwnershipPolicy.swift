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
    struct PartialCompositionSplit: Equatable {
        let committedPrefix: String
        let remainingRawInput: String
    }

    static func supports(rawInput: String, preedit: String) -> Bool {
        !rawInput.isEmpty
            && rawInput.unicodeScalars.allSatisfy(\.isASCII)
            && preedit.unicodeScalars.allSatisfy(\.isASCII)
    }

    static func partialCompositionSplit(
        rawInput: String,
        preedit: String,
        preeditSelectionStart: Int,
        preeditSelectionEnd: Int
    ) -> PartialCompositionSplit? {
        let rawBytes = Array(rawInput.utf8)
        let preeditBytes = Array(preedit.utf8)
        guard !rawBytes.isEmpty,
              rawBytes.allSatisfy({ $0 < 0x80 }),
              preeditBytes.contains(where: { $0 >= 0x80 }),
              preeditSelectionStart > 0,
              preeditSelectionStart <= preeditSelectionEnd,
              preeditSelectionEnd <= preeditBytes.count
        else { return nil }

        let activeDisplayBytes = Array(preeditBytes[preeditSelectionStart..<preeditSelectionEnd])
        guard !activeDisplayBytes.isEmpty,
              activeDisplayBytes.allSatisfy({ $0 < 0x80 })
        else { return nil }

        // Rime adds spaces to preedit to show syllable boundaries; those
        // separators are not present in its raw input buffer.
        let activeRawBytes = activeDisplayBytes.filter { $0 != 0x20 }
        guard !activeRawBytes.isEmpty,
              rawBytes.count >= activeRawBytes.count,
              rawBytes.suffix(activeRawBytes.count).elementsEqual(activeRawBytes)
        else { return nil }

        let prefix = String(decoding: preeditBytes[..<preeditSelectionStart], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else { return nil }
        return PartialCompositionSplit(
            committedPrefix: prefix,
            remainingRawInput: String(decoding: activeRawBytes, as: UTF8.self)
        )
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
