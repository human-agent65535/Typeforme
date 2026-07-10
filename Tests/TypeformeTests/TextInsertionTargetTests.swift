import Foundation
import Testing
@testable import Typeforme

@Suite("TextInsertionTarget")
struct TextInsertionTargetTests {
    @Test func insertionRangeMustRemainExactlyOwned() {
        #expect(TextEditTargetCapture.insertionRangesMatch(captured: nil, current: nil))
        #expect(!TextEditTargetCapture.insertionRangesMatch(
            captured: nil,
            current: CFRange(location: 0, length: 0)
        ))
        #expect(TextEditTargetCapture.insertionRangesMatch(
            captured: CFRange(location: 7, length: 0),
            current: CFRange(location: 7, length: 0)
        ))
        #expect(!TextEditTargetCapture.insertionRangesMatch(
            captured: CFRange(location: 7, length: 0),
            current: CFRange(location: 8, length: 0)
        ))
        #expect(!TextEditTargetCapture.insertionRangesMatch(
            captured: CFRange(location: 7, length: 3),
            current: CFRange(location: 7, length: 2)
        ))
    }
}
