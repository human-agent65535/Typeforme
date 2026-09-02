import Foundation

/// AI results own one marked range, never the surrounding document. Editing or
/// leaving that range invalidates the request even if identical text is retyped.
struct KeyboardPinyinConversionSession {
    struct Source: Equatable {
        let pinyin: String
        let confirmedPrefix: String

        static func composition(
            rawInput: String,
            preedit: String,
            selectionStart: Int,
            selectionEnd: Int
        ) -> Source? {
            guard !rawInput.isEmpty else { return nil }
            if let split = KeyboardRimeInlineEditPolicy.partialCompositionSplit(
                rawInput: rawInput,
                preedit: preedit,
                preeditSelectionStart: selectionStart,
                preeditSelectionEnd: selectionEnd
            ) {
                return Source(pinyin: split.remainingRawInput, confirmedPrefix: split.committedPrefix)
            }
            return Source(pinyin: rawInput, confirmedPrefix: "")
        }

        static func pending(_ input: KeyboardPendingRimeInput) -> Source? {
            guard let pinyin = input.activeEngineInput,
                  !pinyin.isEmpty,
                  let visibleText = input.flattenedLiteralText(),
                  visibleText.hasSuffix(pinyin)
            else { return nil }
            // Earlier raw boundaries (including Return) must not be converted
            // again just because Rime was still starting when they were typed.
            return Source(
                pinyin: pinyin,
                confirmedPrefix: String(visibleText.dropLast(pinyin.count))
            )
        }
    }

    struct Target: Equatable {
        let source: Source
        let documentIdentifier: UUID
        let markedText: String
        let selectionLocation: Int
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
    ) -> Source? {
        guard let request, request.id == requestID else { return nil }
        self.request = nil
        guard isEnabled, isVisible, documentIsCurrent,
              request.target == currentTarget
        else { return nil }
        return request.target.source
    }
}
