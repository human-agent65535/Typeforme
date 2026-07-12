import Testing
@testable import Typeforme

@Suite("Keyboard marked-text ownership")
struct KeyboardMarkedTextOwnershipPolicyTests {
    @Test("Rime target accepts the first key before marked text exists")
    func rimeTargetAcceptsInitialUnmarkedState() {
        #expect(KeyboardMarkedTextOwnershipPolicy.rimeCompositionContextsMatch(
            before: "committed",
            after: "suffix",
            markedText: "",
            anchorBefore: "committed",
            anchorAfter: "suffix"
        ))
    }

    @Test("Rime target accepts a host that excludes marked text")
    func rimeTargetAcceptsExcludedMarkedText() {
        #expect(KeyboardMarkedTextOwnershipPolicy.rimeCompositionContextsMatch(
            before: "committed-s",
            after: "suffix",
            markedText: "sh",
            anchorBefore: "committed-s",
            anchorAfter: "suffix"
        ))
    }

    @Test("Rime target accepts a host that includes marked text")
    func rimeTargetAcceptsIncludedMarkedText() {
        #expect(KeyboardMarkedTextOwnershipPolicy.rimeCompositionContextsMatch(
            before: "committed-ssh",
            after: "suffix",
            markedText: "sh",
            anchorBefore: "committed-s",
            anchorAfter: "suffix"
        ))
    }

    @Test("Rime target does not strip a committed suffix collision")
    func rimeTargetPreservesCommittedSuffixCollision() {
        #expect(KeyboardMarkedTextOwnershipPolicy.rimeCompositionContextsMatch(
            before: "fs",
            after: "",
            markedText: "s",
            anchorBefore: "fs",
            anchorAfter: ""
        ))
    }

    @Test("Rime target rejects a moved insertion point")
    func rimeTargetRejectsMovedInsertionPoint() {
        #expect(!KeyboardMarkedTextOwnershipPolicy.rimeCompositionContextsMatch(
            before: "other",
            after: "",
            markedText: "sh",
            anchorBefore: "original",
            anchorAfter: ""
        ))
    }

    @Test("Host may exclude marked text from an empty document context")
    func excludedMarkedTextMatchesEmptyAnchor() {
        #expect(KeyboardMarkedTextOwnershipPolicy.contextsMatch(
            before: "",
            after: "",
            markedText: "试试到底好不好用啊",
            anchorBefore: "",
            anchorAfter: ""
        ))
    }

    @Test("Host may include marked text in documentContextBeforeInput")
    func includedMarkedTextMatchesAnchor() {
        #expect(KeyboardMarkedTextOwnershipPolicy.contextsMatch(
            before: "prefix预览",
            after: "suffix",
            markedText: "预览",
            anchorBefore: "prefix",
            anchorAfter: "suffix"
        ))
    }

    @Test("Committed context ending in the same text is not mistaken for included marked text")
    func excludedMarkedTextSuffixCollisionMatchesUnstrippedCandidate() {
        #expect(KeyboardMarkedTextOwnershipPolicy.contextsMatch(
            before: "prefix预览",
            after: "",
            markedText: "预览",
            anchorBefore: "prefix预览",
            anchorAfter: ""
        ))
    }

    @Test("Changed surrounding context invalidates ownership")
    func changedContextFailsClosed() {
        #expect(!KeyboardMarkedTextOwnershipPolicy.contextsMatch(
            before: "other预览",
            after: "suffix",
            markedText: "预览",
            anchorBefore: "prefix",
            anchorAfter: "suffix"
        ))
        #expect(!KeyboardMarkedTextOwnershipPolicy.contextsMatch(
            before: "prefix预览",
            after: "other",
            markedText: "预览",
            anchorBefore: "prefix",
            anchorAfter: "suffix"
        ))
    }
}
