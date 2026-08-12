import Foundation
import Testing
@testable import Typeforme

@Suite("Keyboard marked-text ownership")
struct KeyboardMarkedTextOwnershipPolicyTests {
    @Test("Inline editing is limited to unconverted ASCII Rime input")
    func inlineEditingRequiresRawComposition() {
        #expect(KeyboardRimeInlineEditPolicy.supports(rawInput: "niho", preedit: "ni ho"))
        #expect(KeyboardRimeInlineEditPolicy.supports(rawInput: "nv", preedit: "nü"))
        #expect(KeyboardRimeInlineEditPolicy.supports(rawInput: "nue", preedit: "nüe"))
        #expect(KeyboardRimeInlineEditPolicy.supports(rawInput: "lue", preedit: "lüe"))
        #expect(KeyboardRimeInlineEditPolicy.supports(rawInput: "jv", preedit: "ju"))
        #expect(KeyboardRimeInlineEditPolicy.supports(rawInput: "xi'an", preedit: "xi'an"))
        #expect(KeyboardRimeInlineEditPolicy.supports(rawInput: "c'laude", preedit: "c'lau de"))
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

    @Test("Pinyin apostrophe stays inside an active Rime composition")
    func pinyinSeparatorRouting() {
        #expect(KeyboardRimeCompositionPolicy.isPinyinSeparatorContinuation("'", rawInput: "xi"))
        #expect(KeyboardRimeCompositionPolicy.isPinyinSeparatorContinuation("'", rawInput: "xi'an"))
        #expect(!KeyboardRimeCompositionPolicy.isPinyinSeparatorContinuation("'", rawInput: ""))
        #expect(!KeyboardRimeCompositionPolicy.isPinyinSeparatorContinuation("'", rawInput: "http:"))
        #expect(!KeyboardRimeCompositionPolicy.isPinyinSeparatorContinuation(",", rawInput: "xi"))
    }

    @Test("Moving after a partial candidate commits its confirmed prefix and keeps the raw suffix editable")
    func partialCandidateRebasesBeforeInlineEditing() {
        #expect(KeyboardRimeInlineEditPolicy.partialCompositionSplit(
            rawInput: "niao",
            preedit: "你ao",
            preeditSelectionStart: 3,
            preeditSelectionEnd: 5
        ) == KeyboardRimeInlineEditPolicy.PartialCompositionSplit(
            committedPrefix: "你",
            remainingRawInput: "ao"
        ))
        #expect(KeyboardRimeInlineEditPolicy.partialCompositionSplit(
            rawInput: "nihaoma",
            preedit: "你hao ma",
            preeditSelectionStart: 3,
            preeditSelectionEnd: 9
        ) == KeyboardRimeInlineEditPolicy.PartialCompositionSplit(
            committedPrefix: "你",
            remainingRawInput: "haoma"
        ))
        #expect(KeyboardRimeInlineEditPolicy.partialCompositionSplit(
            rawInput: "niao",
            preedit: "niao",
            preeditSelectionStart: 0,
            preeditSelectionEnd: 4
        ) == nil)
        #expect(KeyboardRimeInlineEditPolicy.partialCompositionSplit(
            rawInput: "nihao",
            preedit: "ni hao",
            preeditSelectionStart: 0,
            preeditSelectionEnd: 6
        ) == nil)
        #expect(KeyboardRimeInlineEditPolicy.partialCompositionSplit(
            rawInput: "niao",
            preedit: "你ma",
            preeditSelectionStart: 3,
            preeditSelectionEnd: 5
        ) == nil)
        #expect(KeyboardRimeInlineEditPolicy.partialCompositionSplit(
            rawInput: "ninue",
            preedit: "你nüe",
            preeditSelectionStart: 3,
            preeditSelectionEnd: 7
        ) == KeyboardRimeInlineEditPolicy.PartialCompositionSplit(
            committedPrefix: "你",
            remainingRawInput: "nue"
        ))
        #expect(KeyboardRimeInlineEditPolicy.partialCompositionSplit(
            rawInput: "nijv",
            preedit: "你ju",
            preeditSelectionStart: 3,
            preeditSelectionEnd: 5
        ) == KeyboardRimeInlineEditPolicy.PartialCompositionSplit(
            committedPrefix: "你",
            remainingRawInput: "jv"
        ))
        #expect(KeyboardRimeInlineEditPolicy.partialCompositionSplit(
            rawInput: "nixi'an",
            preedit: "你xi'an",
            preeditSelectionStart: 3,
            preeditSelectionEnd: 8
        ) == KeyboardRimeInlineEditPolicy.PartialCompositionSplit(
            committedPrefix: "你",
            remainingRawInput: "xi'an"
        ))
    }

    @Test("Committing Rime never leaks display-only pinyin transforms")
    func compositionCommitSeparatesConfirmedTextFromRawPinyin() {
        #expect(KeyboardRimeCompositionPolicy.committableText(
            rawInput: "nihao",
            preedit: "ni hao",
            preeditSelectionStart: 0,
            preeditSelectionEnd: 6
        ) == "nihao")
        #expect(KeyboardRimeCompositionPolicy.committableText(
            rawInput: "nv",
            preedit: "nü",
            preeditSelectionStart: 0,
            preeditSelectionEnd: 3
        ) == "nv")
        #expect(KeyboardRimeCompositionPolicy.committableText(
            rawInput: "nue",
            preedit: "nüe",
            preeditSelectionStart: 0,
            preeditSelectionEnd: 4
        ) == "nue")
        #expect(KeyboardRimeCompositionPolicy.committableText(
            rawInput: "lue",
            preedit: "lüe",
            preeditSelectionStart: 0,
            preeditSelectionEnd: 4
        ) == "lue")
        #expect(KeyboardRimeCompositionPolicy.committableText(
            rawInput: "nihao",
            preedit: "你hao",
            preeditSelectionStart: 3,
            preeditSelectionEnd: 6
        ) == "你hao")
        #expect(KeyboardRimeCompositionPolicy.committableText(
            rawInput: "ninue",
            preedit: "你nüe",
            preeditSelectionStart: 3,
            preeditSelectionEnd: 7
        ) == "你nue")
        #expect(KeyboardRimeCompositionPolicy.committableText(
            rawInput: "nihaoa",
            preedit: "你好a",
            preeditSelectionStart: 6,
            preeditSelectionEnd: 7
        ) == "你好a")
        #expect(KeyboardRimeCompositionPolicy.committableText(
            rawInput: "hahaha",
            preedit: "哈哈ha",
            preeditSelectionStart: 6,
            preeditSelectionEnd: 8
        ) == "哈哈ha")
    }

    @Test("Pending Rime transaction keeps engine and literal input in tap order")
    func pendingRimeInputBoundaryCommit() {
        var pending = KeyboardPendingRimeInput()
        pending.appendEngineCharacter("n")
        pending.appendEngineCharacter("i")
        #expect(pending.operations == [.engineCharacters(["n", "i"])])
        #expect(pending.activeEngineInput == "ni")
        #expect(pending.flattenedLiteralText(appending: " ") == "ni ")

        pending.appendRawLiteralBoundary(",")
        pending.appendEngineCharacter("h")
        pending.appendEngineCharacter("a")
        pending.appendEngineCharacter("o")
        #expect(pending.operations == [
            .engineCharacters(["n", "i"]),
            .rawLiteralBoundary(","),
            .engineCharacters(["h", "a", "o"]),
        ])
        #expect(pending.activeEngineInput == "hao")
        #expect(pending.flattenedLiteralText() == "ni,hao")

        #expect(pending.removeLast() == "o")
        #expect(pending.removeLast() == "a")
        #expect(pending.removeLast() == "h")
        #expect(pending.activeEngineInput == nil)
        #expect(pending.removeLast() == ",")
        #expect(pending.activeEngineInput == "ni")
        pending.consumeAfterSuccessfulReplay()
        #expect(pending.isEmpty)
        #expect(pending.flattenedLiteralText() == nil)
        pending.consumeAfterSuccessfulReplay()
        #expect(pending.isEmpty)

        var mixedBoundary = KeyboardPendingRimeInput()
        for character in "hahaha" {
            mixedBoundary.appendEngineCharacter(String(character))
        }
        mixedBoundary.appendRawLiteralBoundary("“")
        #expect(mixedBoundary.operations == [
            .engineCharacters(["h", "a", "h", "a", "h", "a"]),
            .rawLiteralBoundary("“"),
        ])
        #expect(mixedBoundary.flattenedLiteralText() == "hahaha“")
    }

    @Test("Pending literal shortcut remains one reversible tap boundary")
    func pendingRimeLiteralShortcutRemoval() {
        var pending = KeyboardPendingRimeInput()
        pending.appendEngineCharacter("w")
        pending.appendEngineCharacter("w")
        pending.appendEngineCharacter("w")
        pending.appendRawLiteralBoundary(".com")
        pending.appendRawLiteralBoundary("/")

        #expect(pending.operations == [
            .engineCharacters(["w", "w", "w"]),
            .rawLiteralBoundary(".com"),
            .rawLiteralBoundary("/"),
        ])
        #expect(pending.flattenedLiteralText() == "www.com/")
        #expect(pending.removeLast() == "/")
        #expect(pending.removeLast() == ".com")
        #expect(pending.flattenedLiteralText() == "www")
    }

    @Test("Pending Space and Return preserve normal Rime key semantics")
    func pendingRimeSemanticBoundaries() {
        var select = KeyboardPendingRimeInput()
        select.appendEngineCharacter("n")
        select.appendEngineCharacter("i")
        select.appendSpaceKey()
        #expect(select.operations == [
            .engineCharacters(["n", "i"]),
            .spaceKey,
        ])
        #expect(select.flattenedLiteralText() == "ni ")

        var rawReturn = KeyboardPendingRimeInput()
        rawReturn.appendEngineCharacter("n")
        rawReturn.appendEngineCharacter("i")
        rawReturn.appendReturnKey()
        #expect(rawReturn.flattenedLiteralText() == "ni")

        var newlineAfterSelection = select
        newlineAfterSelection.appendReturnKey()
        #expect(newlineAfterSelection.flattenedLiteralText() == "ni \n")

        var repeatedReturn = rawReturn
        repeatedReturn.appendReturnKey()
        #expect(repeatedReturn.operations.suffix(2) == [.returnKey, .returnKey])
        #expect(repeatedReturn.flattenedLiteralText() == "ni\n")

        var repeatedSpace = select
        repeatedSpace.appendSpaceKey()
        #expect(repeatedSpace.flattenedLiteralText() == "ni  ")

        var literalBoundary = KeyboardPendingRimeInput()
        for character in "github" {
            literalBoundary.appendEngineCharacter(String(character))
        }
        literalBoundary.appendRawLiteralBoundary(" ")
        #expect(literalBoundary.operations == [
            .engineCharacters(["g", "i", "t", "h", "u", "b"]),
            .rawLiteralBoundary(" "),
        ])
        #expect(literalBoundary.flattenedLiteralText() == "github ")
        #expect(literalBoundary.removeLast() == " ")
        #expect(literalBoundary.removeLast() == "b")
    }

    @Test("Observing not-ready input never consumes or reshapes its transaction")
    func pendingRimeInputSurvivesRepeatedNotReadyObservations() {
        var pending = KeyboardPendingRimeInput()
        pending.appendEngineCharacter("n")
        pending.appendEngineCharacter("i")
        pending.appendRawLiteralBoundary(",")
        pending.appendEngineCharacter("h")
        let original = pending

        for _ in 0..<3 {
            let replaySnapshot = pending
            #expect(replaySnapshot == original)
            #expect(pending == original)
        }

        pending.consumeAfterSuccessfulReplay()
        #expect(pending.isEmpty)
    }

    @Test("Rime composition remains current only at its captured document target")
    func rimeCompositionUsesDocumentTarget() {
        let captured = UUID()
        #expect(KeyboardRimeCompositionPolicy.targetIsCurrent(
            capturedDocumentIdentifier: captured,
            currentDocumentIdentifier: captured,
            capturedContextBefore: "beforej",
            capturedContextAfter: "after",
            currentContextBefore: "beforej",
            currentContextAfter: "after"
        ))
        #expect(!KeyboardRimeCompositionPolicy.targetIsCurrent(
            capturedDocumentIdentifier: captured,
            currentDocumentIdentifier: UUID(),
            capturedContextBefore: "beforej",
            capturedContextAfter: "after",
            currentContextBefore: "beforej",
            currentContextAfter: "after"
        ))
        #expect(!KeyboardRimeCompositionPolicy.targetIsCurrent(
            capturedDocumentIdentifier: captured,
            currentDocumentIdentifier: captured,
            capturedContextBefore: "beforej",
            capturedContextAfter: "after",
            currentContextBefore: "before",
            currentContextAfter: "after"
        ))
        #expect(!KeyboardRimeCompositionPolicy.targetIsCurrent(
            capturedDocumentIdentifier: captured,
            currentDocumentIdentifier: nil,
            capturedContextBefore: "beforej",
            capturedContextAfter: "after",
            currentContextBefore: "beforej",
            currentContextAfter: "after"
        ))
        #expect(!KeyboardRimeCompositionPolicy.targetIsCurrent(
            capturedDocumentIdentifier: nil,
            currentDocumentIdentifier: nil,
            capturedContextBefore: nil,
            capturedContextAfter: nil,
            currentContextBefore: nil,
            currentContextAfter: nil
        ))
    }

    @Test("Delayed local callbacks preserve Rime ownership while host edits relinquish it")
    func rimeCompositionUsesDelegateBoundary() {
        #expect(KeyboardRimeCompositionPolicy.externalHostChangeResolution(
            hasRimeMarkedTextOwner: true,
            localMutationInProgress: false,
            targetIsCurrent: false,
            documentIdentityIsCurrent: true
        ) == .relinquishCurrentTarget)
        #expect(KeyboardRimeCompositionPolicy.externalHostChangeResolution(
            hasRimeMarkedTextOwner: true,
            localMutationInProgress: false,
            targetIsCurrent: false,
            documentIdentityIsCurrent: false
        ) == .discardStaleTarget)
        #expect(KeyboardRimeCompositionPolicy.externalHostChangeResolution(
            hasRimeMarkedTextOwner: true,
            localMutationInProgress: true,
            targetIsCurrent: false,
            documentIdentityIsCurrent: true
        ) == .ignore)
        #expect(KeyboardRimeCompositionPolicy.externalHostChangeResolution(
            hasRimeMarkedTextOwner: true,
            localMutationInProgress: false,
            targetIsCurrent: true,
            documentIdentityIsCurrent: true
        ) == .ignore)
        #expect(KeyboardRimeCompositionPolicy.externalHostChangeResolution(
            hasRimeMarkedTextOwner: false,
            localMutationInProgress: false,
            targetIsCurrent: false,
            documentIdentityIsCurrent: true
        ) == .ignore)
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
        #expect(!KeyboardLivePartialOwnershipPolicy.ownsMarkedText(
            expectedCommandID: "command",
            commandID: "command",
            expectedDocumentIdentifier: nil,
            documentIdentifier: nil,
            expectedText: "语音预览",
            activeMarkedText: "语音预览",
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
        #expect(!KeyboardLivePartialOwnershipPolicy.insertionTargetIsCurrent(
            capturedDocumentIdentifier: document,
            currentDocumentIdentifier: nil,
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

    @Test("Only the keyboard controller that captured the command may consume its voice result")
    func voiceResultUsesCommandScopedControllerOwnership() {
        #expect(KeyboardLivePartialOwnershipPolicy.controllerOwnsCommand(
            "voice-command",
            insertionAnchorCommandID: "voice-command",
            livePartialCommandID: nil,
            rewriteTargetCommandID: nil
        ))
        #expect(KeyboardLivePartialOwnershipPolicy.controllerOwnsCommand(
            "voice-command",
            insertionAnchorCommandID: nil,
            livePartialCommandID: "voice-command",
            rewriteTargetCommandID: nil
        ))
        #expect(KeyboardLivePartialOwnershipPolicy.controllerOwnsCommand(
            "rewrite-command",
            insertionAnchorCommandID: nil,
            livePartialCommandID: nil,
            rewriteTargetCommandID: "rewrite-command"
        ))
        #expect(!KeyboardLivePartialOwnershipPolicy.controllerOwnsCommand(
            "observed-command",
            insertionAnchorCommandID: nil,
            livePartialCommandID: nil,
            rewriteTargetCommandID: nil
        ))
        #expect(!KeyboardLivePartialOwnershipPolicy.controllerOwnsCommand(
            "new-command",
            insertionAnchorCommandID: "old-command",
            livePartialCommandID: "old-command",
            rewriteTargetCommandID: nil
        ))
    }
}
