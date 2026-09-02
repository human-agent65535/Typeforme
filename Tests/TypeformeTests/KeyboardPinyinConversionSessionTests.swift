import Foundation
import Testing
@testable import Typeforme

@Suite("KeyboardPinyinConversionSession")
struct KeyboardPinyinConversionSessionTests {
    @Test func sendsRawPinyinWithoutRimeDisplaySegmentation() throws {
        let source = try #require(KeyboardPinyinConversionSession.Source.composition(
            rawInput: "nihaoma", preedit: "ni hao ma", selectionStart: 0, selectionEnd: 9
        ))
        #expect(source.pinyin == "nihaoma")
        #expect(source.confirmedPrefix.isEmpty)
        let umlaut = try #require(KeyboardPinyinConversionSession.Source.composition(
            rawInput: "nvhai", preedit: "nü hai", selectionStart: 0, selectionEnd: 7
        ))
        #expect(umlaut.pinyin == "nvhai")
    }

    @Test func preservesAlreadyConfirmedChineseOutsideAIInput() throws {
        let preedit = "你hao ma"
        let source = try #require(KeyboardPinyinConversionSession.Source.composition(
            rawInput: "nihaoma", preedit: preedit, selectionStart: "你".utf8.count, selectionEnd: preedit.utf8.count
        ))
        #expect(source.pinyin == "haoma")
        #expect(source.confirmedPrefix == "你")
    }

    @Test func startupInputNeedsNoEngineAndPreservesEarlierRawBoundary() throws {
        var pending = KeyboardPendingRimeInput()
        for character in "hello" { pending.appendEngineCharacter(String(character)) }
        pending.appendReturnKey()
        for character in "nihaoma" { pending.appendEngineCharacter(String(character)) }
        let source = try #require(KeyboardPinyinConversionSession.Source.pending(pending))
        #expect(source.pinyin == "nihaoma")
        #expect(source.confirmedPrefix == "hello")
    }

    @Test func duplicateSpaceStartsOnlyOneRequestAndResultIsConsumedOnce() throws {
        var session = KeyboardPinyinConversionSession()
        let target = makeTarget()
        let started = session.begin(target: target)
        let request = try #require(started)
        let duplicate = session.begin(target: target)
        #expect(duplicate == nil)
        let first = session.takeResult(requestID: request.id, currentTarget: target, documentIsCurrent: true, isEnabled: true, isVisible: true)
        let second = session.takeResult(requestID: request.id, currentTarget: target, documentIsCurrent: true, isEnabled: true, isVisible: true)
        #expect(first == target.source)
        #expect(second == nil)
    }

    @Test func cancellationRejectsOldResultEvenAfterIdenticalInputIsRetyped() throws {
        var session = KeyboardPinyinConversionSession()
        let target = makeTarget()
        let first = session.begin(target: target)
        let old = try #require(first)
        session.cancel()
        let second = session.begin(target: target)
        let current = try #require(second)
        let oldResult = session.takeResult(requestID: old.id, currentTarget: target, documentIsCurrent: true, isEnabled: true, isVisible: true)
        #expect(oldResult == nil)
        #expect(session.request?.id == current.id)
        let currentResult = session.takeResult(requestID: current.id, currentTarget: target, documentIsCurrent: true, isEnabled: true, isVisible: true)
        #expect(currentResult == target.source)
    }

    @Test(arguments: 0..<5) func losingOwnershipDiscardsResult(reason: Int) throws {
        var session = KeyboardPinyinConversionSession()
        let target = makeTarget()
        let started = session.begin(target: target)
        let request = try #require(started)
        let changedTarget = makeTarget(documentIdentifier: reason == 0 ? UUID() : target.documentIdentifier, selectionLocation: reason == 1 ? 1 : target.selectionLocation)
        let result = session.takeResult(
            requestID: request.id,
            currentTarget: changedTarget,
            documentIsCurrent: reason != 2,
            isEnabled: reason != 3,
            isVisible: reason != 4
        )
        #expect(result == nil)
        #expect(session.request == nil)
    }

    private func makeTarget(documentIdentifier: UUID = UUID(), selectionLocation: Int = 9) -> KeyboardPinyinConversionSession.Target {
        .init(
            source: .init(pinyin: "nihaoma", confirmedPrefix: ""),
            documentIdentifier: documentIdentifier,
            markedText: "ni hao ma",
            selectionLocation: selectionLocation
        )
    }
}
