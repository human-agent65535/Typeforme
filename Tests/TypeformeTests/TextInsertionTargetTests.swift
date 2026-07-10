import Foundation
import Testing
@testable import Typeforme

@Suite("TextInsertionTarget")
struct TextInsertionTargetTests {
    @Test func insertionEvidenceMustRemainExactlyOwned() {
        #expect(!TextEditTargetCapture.insertionEvidenceMatches(
            capturedRange: nil,
            currentRange: nil,
            capturedContextBefore: nil,
            capturedContextAfter: nil,
            currentContextBefore: nil,
            currentContextAfter: nil
        ))
        #expect(TextEditTargetCapture.insertionEvidenceMatches(
            capturedRange: nil,
            currentRange: nil,
            capturedContextBefore: "",
            capturedContextAfter: "",
            currentContextBefore: "",
            currentContextAfter: ""
        ))
        #expect(!TextEditTargetCapture.insertionEvidenceMatches(
            capturedRange: nil,
            currentRange: nil,
            capturedContextBefore: "before",
            capturedContextAfter: "after",
            currentContextBefore: "changed",
            currentContextAfter: "after"
        ))
        #expect(TextEditTargetCapture.insertionEvidenceMatches(
            capturedRange: CFRange(location: 7, length: 0),
            currentRange: CFRange(location: 7, length: 0),
            capturedContextBefore: nil,
            capturedContextAfter: nil,
            currentContextBefore: nil,
            currentContextAfter: nil
        ))
        #expect(TextEditTargetCapture.insertionEvidenceMatches(
            capturedRange: CFRange(location: 7, length: 0),
            currentRange: CFRange(location: 7, length: 0),
            capturedContextBefore: "before",
            capturedContextAfter: "after",
            currentContextBefore: "before",
            currentContextAfter: "after"
        ))
        #expect(!TextEditTargetCapture.insertionEvidenceMatches(
            capturedRange: CFRange(location: 7, length: 0),
            currentRange: CFRange(location: 7, length: 0),
            capturedContextBefore: "before",
            capturedContextAfter: "after",
            currentContextBefore: "before",
            currentContextAfter: "changed"
        ))
        #expect(!TextEditTargetCapture.insertionEvidenceMatches(
            capturedRange: CFRange(location: 7, length: 0),
            currentRange: CFRange(location: 8, length: 0),
            capturedContextBefore: "before",
            capturedContextAfter: "after",
            currentContextBefore: "before",
            currentContextAfter: "after"
        ))
        #expect(!TextEditTargetCapture.insertionEvidenceMatches(
            capturedRange: CFRange(location: 7, length: 3),
            currentRange: CFRange(location: 7, length: 2),
            capturedContextBefore: nil,
            capturedContextAfter: nil,
            currentContextBefore: nil,
            currentContextAfter: nil
        ))
    }
}
