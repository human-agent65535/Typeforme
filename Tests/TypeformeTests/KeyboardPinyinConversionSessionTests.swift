import Foundation
import Testing
@testable import Typeforme

@Suite("KeyboardPinyinConversionSession")
struct KeyboardPinyinConversionSessionTests {
    @Test func duplicateTapStartsOneRequestAndResultIsConsumedOnce() throws {
        var session = KeyboardPinyinConversionSession()
        let target = makeTarget()
        let started = session.begin(target: target)
        let request = try #require(started)
        let duplicate = session.begin(target: target)
        #expect(duplicate == nil)
        let first = session.takeResult(requestID: request.id, currentTarget: target, documentIsCurrent: true, isEnabled: true, isVisible: true)
        let second = session.takeResult(requestID: request.id, currentTarget: target, documentIsCurrent: true, isEnabled: true, isVisible: true)
        #expect(first)
        #expect(!second)
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
        #expect(!oldResult)
        #expect(session.request?.id == current.id)
        let currentResult = session.takeResult(requestID: current.id, currentTarget: target, documentIsCurrent: true, isEnabled: true, isVisible: true)
        #expect(currentResult)
    }

    @Test(arguments: 0..<8) func losingInputOwnershipDiscardsResult(reason: Int) throws {
        var session = KeyboardPinyinConversionSession()
        let target = makeTarget()
        let started = session.begin(target: target)
        let request = try #require(started)
        let changedTarget = KeyboardPinyinConversionSession.Target(
            documentIdentifier: reason == 0 ? UUID() : target.documentIdentifier,
            contextBefore: reason == 1 ? "你好 hello niza" : target.contextBefore,
            selectedText: reason == 2 ? "ma" : target.selectedText,
            contextAfter: reason == 3 ? " 明天见" : target.contextAfter
        )
        let result = session.takeResult(
            requestID: request.id,
            currentTarget: reason == 4 ? nil : changedTarget,
            documentIsCurrent: reason != 5,
            isEnabled: reason != 6,
            isVisible: reason != 7
        )
        #expect(!result)
        #expect(session.request == nil)
    }

    @Test func selectAllSnapshotKeepsChineseEnglishAndPinyinTogether() throws {
        var session = KeyboardPinyinConversionSession()
        let target = KeyboardPinyinConversionSession.Target(
            documentIdentifier: UUID(), contextBefore: nil,
            selectedText: "你好 hello nizaima", contextAfter: nil
        )
        let started = session.begin(target: target)
        let request = try #require(started)
        #expect(request.target.selectedText == "你好 hello nizaima")
        let result = session.takeResult(requestID: request.id, currentTarget: target, documentIsCurrent: true, isEnabled: true, isVisible: true)
        #expect(result)
    }

    private func makeTarget() -> KeyboardPinyinConversionSession.Target {
        .init(
            documentIdentifier: UUID(),
            contextBefore: "你好 hello nizaima",
            selectedText: nil,
            contextAfter: ""
        )
    }
}
