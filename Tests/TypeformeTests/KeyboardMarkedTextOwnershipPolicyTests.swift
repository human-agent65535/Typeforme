import Foundation
import Testing
@testable import Typeforme

@Suite("Keyboard marked-text ownership")
struct KeyboardMarkedTextOwnershipPolicyTests {
    @Test("Inline editing is limited to unconverted ASCII Rime input")
    func inlineEditingRequiresRawComposition() {
        #expect(KeyboardRimeInlineEditPolicy.supports(rawInput: "niho", preedit: "ni ho"))
        #expect(!KeyboardRimeInlineEditPolicy.supports(rawInput: "niho", preedit: "你ho"))
        #expect(!KeyboardRimeInlineEditPolicy.supports(rawInput: "", preedit: ""))
    }

    @Test("Inline editing modifies the whole raw input without moving Rime's candidate caret")
    func editsWholeInlineInput() {
        #expect(KeyboardRimeInlineEditPolicy.clampedCaretOffset(-1, in: "niho") == 0)
        #expect(KeyboardRimeInlineEditPolicy.clampedCaretOffset(2, in: "niho") == 2)
        #expect(KeyboardRimeInlineEditPolicy.clampedCaretOffset(99, in: "niho") == 4)
        #expect(KeyboardRimeInlineEditPolicy.inserting("a", in: "niho", at: 3) == "nihao")
        #expect(KeyboardRimeInlineEditPolicy.deletingCharacter(before: 3, in: "nihao") == "niao")
        #expect(KeyboardRimeInlineEditPolicy.deletingCharacter(before: 0, in: "nihao") == nil)
    }

    @Test("Rime composition remains current only in its captured document")
    func rimeCompositionUsesDocumentIdentity() {
        let captured = UUID()
        #expect(KeyboardRimeCompositionPolicy.targetIsCurrent(
            capturedDocumentIdentifier: captured,
            currentDocumentIdentifier: captured
        ))
        #expect(!KeyboardRimeCompositionPolicy.targetIsCurrent(
            capturedDocumentIdentifier: captured,
            currentDocumentIdentifier: UUID()
        ))
    }

    @Test("Voice partial ownership is command and document scoped")
    func voicePartialOwnershipIsIndependentFromRime() {
        let document = UUID()
        #expect(KeyboardLivePartialOwnershipPolicy.ownsMarkedText(
            expectedCommandID: "command",
            commandID: "command",
            expectedDocumentIdentifier: document,
            documentIdentifier: document,
            expectedText: "语音预览",
            activeMarkedText: "语音预览",
            hasLivePartialOwner: true
        ))
        #expect(!KeyboardLivePartialOwnershipPolicy.ownsMarkedText(
            expectedCommandID: "command",
            commandID: "other",
            expectedDocumentIdentifier: document,
            documentIdentifier: document,
            expectedText: "语音预览",
            activeMarkedText: "语音预览",
            hasLivePartialOwner: true
        ))
        #expect(!KeyboardLivePartialOwnershipPolicy.ownsMarkedText(
            expectedCommandID: "command",
            commandID: "command",
            expectedDocumentIdentifier: document,
            documentIdentifier: UUID(),
            expectedText: "语音预览",
            activeMarkedText: "语音预览",
            hasLivePartialOwner: true
        ))
        #expect(!KeyboardLivePartialOwnershipPolicy.ownsMarkedText(
            expectedCommandID: "command",
            commandID: "command",
            expectedDocumentIdentifier: document,
            documentIdentifier: document,
            expectedText: "语音预览",
            activeMarkedText: "拼音",
            hasLivePartialOwner: true
        ))
    }

    @Test("Voice establishes its initial marked text only at the captured insertion target")
    func voiceInitialInsertionTargetIsStable() {
        let document = UUID()

        #expect(KeyboardLivePartialOwnershipPolicy.insertionTargetIsCurrent(
            capturedDocumentIdentifier: document,
            currentDocumentIdentifier: document,
            capturedContextBefore: "",
            capturedContextAfter: "",
            currentContextBefore: "",
            currentContextAfter: ""
        ))
        #expect(KeyboardLivePartialOwnershipPolicy.insertionTargetIsCurrent(
            capturedDocumentIdentifier: document,
            currentDocumentIdentifier: document,
            capturedContextBefore: "before",
            capturedContextAfter: "after",
            currentContextBefore: "before",
            currentContextAfter: "after"
        ))
        #expect(!KeyboardLivePartialOwnershipPolicy.insertionTargetIsCurrent(
            capturedDocumentIdentifier: document,
            currentDocumentIdentifier: document,
            capturedContextBefore: "before",
            capturedContextAfter: "after",
            currentContextBefore: "changed",
            currentContextAfter: "after"
        ))
        #expect(!KeyboardLivePartialOwnershipPolicy.insertionTargetIsCurrent(
            capturedDocumentIdentifier: document,
            currentDocumentIdentifier: UUID(),
            capturedContextBefore: "before",
            capturedContextAfter: "after",
            currentContextBefore: "before",
            currentContextAfter: "after"
        ))
    }
}
