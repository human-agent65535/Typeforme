import Testing
@testable import Typeforme

@Suite("Keyboard whole-input rewrite")
struct KeyboardWholeInputRewritePolicyTests {
    @Test("Select all remains a valid whole-input Wand target")
    func selectAllUsesSelectedText() {
        #expect(
            KeyboardWholeInputRewritePolicy.source(
                contextBefore: "",
                selectedText: "Rewrite all of this",
                contextAfter: ""
            ) == .selectedText
        )
    }

    @Test("No selection keeps using the surrounding input")
    func noSelectionUsesSurroundingContext() {
        #expect(
            KeyboardWholeInputRewritePolicy.source(
                contextBefore: "Rewrite all of this",
                selectedText: nil,
                contextAfter: ""
            ) == .surroundingContext
        )
    }

    @Test("A partial selection does not change whole-input Wand ownership")
    func partialSelectionUsesSurroundingContext() {
        #expect(
            KeyboardWholeInputRewritePolicy.source(
                contextBefore: "Rewrite ",
                selectedText: "all",
                contextAfter: " of this"
            ) == .surroundingContext
        )
    }

    @Test("Whitespace alone is not a rewrite target")
    func whitespaceIsNotATarget() {
        #expect(
            KeyboardWholeInputRewritePolicy.source(
                contextBefore: " \n",
                selectedText: "\t",
                contextAfter: nil
            ) == nil
        )
    }
}
