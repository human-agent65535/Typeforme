import Foundation

enum KeyboardRimeCompositionPolicy {
    enum ExternalHostChangeResolution: Equatable {
        case ignore
        case relinquishCurrentTarget
        case discardStaleTarget
    }

    static func targetIsCurrent(
        capturedDocumentIdentifier: UUID?,
        currentDocumentIdentifier: UUID?,
        capturedContextBefore: String?,
        capturedContextAfter: String?,
        currentContextBefore: String?,
        currentContextAfter: String?
    ) -> Bool {
        guard let capturedDocumentIdentifier,
              let currentDocumentIdentifier
        else { return false }
        return capturedDocumentIdentifier == currentDocumentIdentifier
            && capturedContextBefore == currentContextBefore
            && capturedContextAfter == currentContextAfter
    }

    /// A third-party keyboard receives nil `UITextInput` callback arguments, so
    /// the callback boundary alone cannot distinguish a host edit from a
    /// delayed callback for this keyboard's own `setMarkedText` operation. A
    /// still-matching document/context snapshot remains keyboard-owned. Once
    /// that target changes, relinquish visible text without replaying it; a
    /// changed document fails closed without touching the new insertion target.
    static func externalHostChangeResolution(
        hasRimeMarkedTextOwner: Bool,
        localMutationInProgress: Bool,
        targetIsCurrent: Bool,
        documentIdentityIsCurrent: Bool
    ) -> ExternalHostChangeResolution {
        guard hasRimeMarkedTextOwner,
              !localMutationInProgress,
              !targetIsCurrent
        else {
            return .ignore
        }
        return documentIdentityIsCurrent ? .relinquishCurrentTarget : .discardStaleTarget
    }

    /// Returns the text that may leave Rime's marked-text session. Rime's
    /// preedit is presentation, not source text: it inserts syllable spacing
    /// and renders pinyin `u`/`v` as `ü`. Only a prefix that Rime has actually
    /// converted may come from the preedit; the active suffix remains raw.
    static func committableText(
        rawInput: String,
        preedit: String,
        preeditSelectionStart: Int,
        preeditSelectionEnd: Int,
        preferRawInput: Bool = false
    ) -> String {
        guard !rawInput.isEmpty else { return "" }
        guard !preferRawInput else { return rawInput }
        guard let split = KeyboardRimeInlineEditPolicy.partialCompositionSplit(
            rawInput: rawInput,
            preedit: preedit,
            preeditSelectionStart: preeditSelectionStart,
            preeditSelectionEnd: preeditSelectionEnd
        ) else { return rawInput }
        return split.committedPrefix + split.remainingRawInput
    }

    /// Apostrophe is Rime's explicit syllable separator. While an ASCII
    /// composition is active it belongs to the engine (for example `xi'an`),
    /// not to the direct boundary that commits the visible composition first.
    static func isPinyinSeparatorContinuation(_ character: String, rawInput: String) -> Bool {
        character == "'"
            && !rawInput.isEmpty
            && rawInput.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && (CharacterSet.letters.contains(scalar) || scalar == "'")
            }
    }
}

/// Ordered input accepted while Rime is starting. Engine and literal chunks
/// remain distinct so replay can commit each composition boundary and then
/// resume a new composition without reordering taps.
struct KeyboardPendingRimeInput: Equatable {
    enum Operation: Equatable {
        case engineCharacters([String])
        /// A normal Space key is semantic while pinyin is active: Rime chooses
        /// the first candidate. It must not be flattened to literal text merely
        /// because the engine is still starting.
        case spaceKey
        /// One direct-text boundary: commit the raw engine buffer exactly as
        /// Return would while Rime is unavailable, then append the key text.
        /// It must never ask Rime to select a candidate.
        case rawLiteralBoundary(String)
        /// Return commits active raw pinyin; if an earlier pending operation
        /// already ended composition, it behaves as a normal newline.
        case returnKey
    }

    private(set) var operations: [Operation] = []

    var isEmpty: Bool {
        operations.isEmpty
    }

    mutating func appendEngineCharacter(_ character: String) {
        guard !character.isEmpty else { return }
        if case .engineCharacters(var characters)? = operations.last {
            characters.append(character)
            operations[operations.count - 1] = .engineCharacters(characters)
        } else {
            operations.append(.engineCharacters([character]))
        }
    }

    mutating func appendSpaceKey() {
        operations.append(.spaceKey)
    }

    mutating func appendRawLiteralBoundary(_ text: String) {
        guard !text.isEmpty else { return }
        operations.append(.rawLiteralBoundary(text))
    }

    mutating func appendReturnKey() {
        operations.append(.returnKey)
    }

    @discardableResult
    mutating func removeLast() -> String? {
        guard let operation = operations.popLast() else { return nil }
        switch operation {
        case .engineCharacters(var characters):
            let removed = characters.removeLast()
            if !characters.isEmpty {
                operations.append(.engineCharacters(characters))
            }
            return removed
        case .spaceKey:
            return " "
        case .rawLiteralBoundary(let text):
            return text
        case .returnKey:
            return ""
        }
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        operations.removeAll(keepingCapacity: keepingCapacity)
    }

    mutating func consumeAfterSuccessfulReplay() {
        removeAll(keepingCapacity: true)
    }

    var activeEngineInput: String? {
        guard case .engineCharacters(let characters)? = operations.last else { return nil }
        return characters.joined()
    }

    /// Lossless raw fallback used only when an ownership boundary must finish
    /// before Rime becomes ready. Semantic Space/Return keys are flattened in
    /// their original order; normal replay still executes them through Rime.
    func flattenedLiteralText(appending suffix: String = "") -> String? {
        guard !isEmpty else { return nil }
        var hasActiveEngineInput = false
        let text = operations.reduce(into: "") { result, operation in
            switch operation {
            case .engineCharacters(let characters):
                result += characters.joined()
                hasActiveEngineInput = !characters.isEmpty
            case .spaceKey:
                result += " "
                hasActiveEngineInput = false
            case .rawLiteralBoundary(let text):
                result += text
                hasActiveEngineInput = false
            case .returnKey:
                if !hasActiveEngineInput {
                    result += "\n"
                }
                hasActiveEngineInput = false
            }
        }
        return text + suffix
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
            && isEquivalentRawPreedit(rawInput: rawInput, preedit: preedit)
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
              preeditSelectionStart > 0,
              preeditSelectionStart <= preeditSelectionEnd,
              preeditSelectionEnd <= preeditBytes.count
        else { return nil }

        let activeDisplayBytes = Array(preeditBytes[preeditSelectionStart..<preeditSelectionEnd])
        let activeDisplay = String(decoding: activeDisplayBytes, as: UTF8.self)
        guard let remainingRawInput = rawSuffix(
            matchingActivePreedit: activeDisplay,
            in: rawInput
        )
        else { return nil }

        let prefix = String(decoding: preeditBytes[..<preeditSelectionStart], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        let rawPrefix = String(rawInput.dropLast(remainingRawInput.count))
        guard !prefix.isEmpty,
              !isEquivalentRawPreedit(rawInput: rawPrefix, preedit: prefix)
        else { return nil }
        return PartialCompositionSplit(
            committedPrefix: prefix,
            remainingRawInput: remainingRawInput
        )
    }

    private static func rawSuffix(
        matchingActivePreedit activePreedit: String,
        in rawInput: String
    ) -> String? {
        let displayScalars = normalizedRimeScalars(activePreedit)
        let rawScalars = Array(rawInput.unicodeScalars)
        guard !displayScalars.isEmpty else { return nil }

        // Apostrophes are Rime delimiters, so the raw suffix can contain more
        // scalars than its displayed spelling. Keep the shortest matching raw
        // suffix; this drops a delimiter immediately before the active segment
        // while preserving delimiters inside that segment.
        var matchingSuffix: String?
        for startIndex in rawScalars.indices {
            let suffix = Array(rawScalars[startIndex...])
            let normalizedSuffix = suffix.filter { !isRimePreeditSeparator($0) }
            guard normalizedSuffix.count == displayScalars.count,
                  scalarsAreEquivalent(
                      rawScalars: normalizedSuffix,
                      displayScalars: displayScalars
                  )
            else { continue }
            matchingSuffix = String(String.UnicodeScalarView(suffix))
        }
        return matchingSuffix
    }

    private static func isEquivalentRawPreedit(rawInput: String, preedit: String) -> Bool {
        let rawScalars = normalizedRimeScalars(rawInput)
        let displayScalars = normalizedRimeScalars(preedit)
        return scalarsAreEquivalent(rawScalars: rawScalars, displayScalars: displayScalars)
    }

    private static func normalizedRimeScalars(_ text: String) -> [UnicodeScalar] {
        text.unicodeScalars.filter { !isRimePreeditSeparator($0) }
    }

    private static func isRimePreeditSeparator(_ scalar: UnicodeScalar) -> Bool {
        scalar == " " || scalar == "'"
    }

    private static func scalarsAreEquivalent(
        rawScalars: [UnicodeScalar],
        displayScalars: [UnicodeScalar]
    ) -> Bool {
        guard rawScalars.count == displayScalars.count else { return false }
        for index in rawScalars.indices {
            let raw = rawScalars[index]
            let display = displayScalars[index]
            if raw == display { continue }
            if display == "ü", raw == "u" || raw == "v" { continue }
            if display == "u", raw == "v", index > 0,
               "jqxy".unicodeScalars.contains(rawScalars[index - 1]) {
                continue
            }
            return false
        }
        return true
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
    static func controllerOwnsCommand(
        _ commandID: String,
        insertionAnchorCommandID: String?,
        livePartialCommandID: String?,
        rewriteTargetCommandID: String?
    ) -> Bool {
        commandID == insertionAnchorCommandID
            || commandID == livePartialCommandID
            || commandID == rewriteTargetCommandID
    }

    static func insertionTargetIsCurrent(
        capturedDocumentIdentifier: UUID?,
        currentDocumentIdentifier: UUID?,
        capturedContextBefore: String,
        capturedContextAfter: String,
        currentContextBefore: String,
        currentContextAfter: String
    ) -> Bool {
        guard let capturedDocumentIdentifier,
              let currentDocumentIdentifier
        else { return false }
        return capturedDocumentIdentifier == currentDocumentIdentifier
            && capturedContextBefore == currentContextBefore
            && capturedContextAfter == currentContextAfter
    }

    static func ownsMarkedText(
        expectedCommandID: String,
        commandID: String,
        expectedDocumentIdentifier: UUID?,
        documentIdentifier: UUID?,
        expectedText: String,
        activeMarkedText: String,
        hasLivePartialOwner: Bool
    ) -> Bool {
        guard let expectedDocumentIdentifier,
              let documentIdentifier
        else { return false }
        return hasLivePartialOwner
            && !expectedText.isEmpty
            && expectedCommandID == commandID
            && expectedDocumentIdentifier == documentIdentifier
            && expectedText == activeMarkedText
    }
}
