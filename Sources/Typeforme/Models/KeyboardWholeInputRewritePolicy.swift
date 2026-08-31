import Foundation

enum KeyboardWholeInputRewriteSource: Equatable {
    case selectedText
    case surroundingContext
}

enum KeyboardWholeInputRewritePolicy {
    /// UIKit exposes a select-all target only through `selectedText`; both
    /// document-context properties are empty in that shape. Keep Wand's
    /// whole-input ownership while routing select-all through the existing
    /// selection replacement path.
    static func source(
        contextBefore: String?,
        selectedText: String?,
        contextAfter: String?
    ) -> KeyboardWholeInputRewriteSource? {
        let selectedText = selectedText ?? ""
        let surroundingContext = (contextBefore ?? "") + (contextAfter ?? "")
        let hasSelectedText = !selectedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let hasSurroundingContext = !surroundingContext
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        if hasSelectedText, !hasSurroundingContext {
            return .selectedText
        }
        return hasSurroundingContext ? .surroundingContext : nil
    }
}
