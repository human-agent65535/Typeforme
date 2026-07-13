import Testing
@testable import Typeforme

@Suite("Verbatim span mask")
struct VerbatimSpanMaskTests {
    @Test func protectsVersionsTimesGroupedNumbersAndOrderedListMarkers() {
        let input = "模型是Qwen3.6-27B 时间3:30 金额1,000.50\n1. item"
        let mask = VerbatimSpanMask(input)

        #expect(mask.entries.map(\.text) == ["Qwen3.6-27B", "3:30", "1,000.50", "1."])
        #expect(mask.restoring(mask.maskedText) == input)
    }

    @Test func protectsOverlappingTechnicalSpansAndRoundTrips() throws {
        let input = """
        打开 https://例子.test/資料?q=a,b&next=/使用者/資料#繁體，然后检查 `x!=y && foo(a,b)`。
        ```json
          {"path":"/使用者/資料", "q":"繁體,保留?"}
        ```
        """
        let mask = VerbatimSpanMask(input)

        #expect(!mask.entries.isEmpty)
        #expect(try #require(mask.restoring(mask.maskedText)) == input)
    }

    @Test func uriStopsAtChineseSentencePunctuation() throws {
        let input = "打开 https://example.com/search?q=a,b&next=/users#frag，然后继续"
        let mask = VerbatimSpanMask(input)
        let uri = try #require(mask.entries.first { $0.text.hasPrefix("https://") })

        #expect(uri.text == "https://example.com/search?q=a,b&next=/users#frag")
        #expect(try #require(mask.restoring(mask.maskedText)) == input)
    }

    @Test func uriExcludesTrailingASCIISentencePunctuationAndClosers() throws {
        let input = "See (https://example.com/path?q=a,b). Next"
        let mask = VerbatimSpanMask(input)
        let uri = try #require(mask.entries.first { $0.text.hasPrefix("https://") })

        #expect(uri.text == "https://example.com/path?q=a,b")
        #expect(try #require(mask.restoring(mask.maskedText)) == input)
    }

    @Test func unclosedInlineCodeIsProtectedThroughEndOfLine() throws {
        let input = "before `x!=y && foo(a,b)\nafter"
        let mask = VerbatimSpanMask(input)
        let code = try #require(mask.entries.first { $0.text.hasPrefix("`x!=y") })

        #expect(code.text == "`x!=y && foo(a,b)")
        #expect(try #require(mask.restoring(mask.maskedText)) == input)
    }

    @Test func unclosedFenceIsProtectedThroughEndOfInput() throws {
        let input = "before\n```json\n  {\"q\":\"a,b?\"}\n"
        let mask = VerbatimSpanMask(input)
        let fence = try #require(mask.entries.first { $0.text.hasPrefix("```json") })

        #expect(fence.text == "```json\n  {\"q\":\"a,b?\"}\n")
        #expect(try #require(mask.restoring(mask.maskedText)) == input)
    }

    @Test func markerCollisionAdvancesSalt() throws {
        let collidingPrefix = VerbatimSpanMask.markerPrefix(salt: 0)
        let input = "\(collidingPrefix) https://example.com?q=a,b"
        let mask = VerbatimSpanMask(input)

        #expect(mask.markerPrefix == VerbatimSpanMask.markerPrefix(salt: 1))
        #expect(try #require(mask.restoring(mask.maskedText)) == input)
    }

    @Test func restorationRejectsMissingDuplicatedAndReorderedMarkers() throws {
        let input = "https://a.example?q=1 /users"
        let mask = VerbatimSpanMask(input)
        #expect(mask.entries.count >= 2)
        let first = try #require(mask.entries.first)
        let last = try #require(mask.entries.last)

        #expect(mask.restoring(mask.maskedText.replacingOccurrences(of: first.token, with: "")) == nil)
        #expect(mask.restoring(mask.maskedText + first.token) == nil)
        let reordered = mask.maskedText
            .replacingOccurrences(of: first.token, with: "TEMP")
            .replacingOccurrences(of: last.token, with: first.token)
            .replacingOccurrences(of: "TEMP", with: last.token)
        #expect(mask.restoring(reordered) == nil)
    }
}
