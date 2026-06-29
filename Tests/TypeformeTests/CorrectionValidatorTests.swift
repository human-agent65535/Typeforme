import Testing
@testable import Typeforme

/// Rejection coverage for correction output validation.
@Suite("CorrectionValidator")
struct CorrectionValidatorTests {

    @Test func emptyTextOnCommitRejected() {
        let result = CorrectionResult(action: .commit, text: "  ", risk: .low)
        let req = makeRequest(raw: "hello")
        #expect(throws: CorrectionValidationError.self) {
            try CorrectionValidator.validate(result, for: req)
        }
    }

    @Test func commitLengthCapUsesRawTranscript() throws {
        // Clean mode allows normal punctuation/spacing expansion while still
        // rejecting essay-length hallucinations.
        let result = CorrectionResult(action: .commit,
                                      text: String(repeating: "x", count: 79),
                                      risk: .low)
        try CorrectionValidator.validate(
            result,
            for: makeRequest(raw: String(repeating: "a", count: 10), correctionMode: .clean)
        )
    }

    @Test func shortMixedLanguageRewriteCanExpandPastDoubleRawLength() throws {
        let result = CorrectionResult(
            action: .commit,
            text: "xin chào，今天测试一下越南语和中文混合输入，不要翻译。",
            risk: .low
        )
        try CorrectionValidator.validate(
            result,
            for: makeRequest(raw: "xin chào 今天测试一下越南语和中文混合输入，不要翻译", correctionMode: .polishPlus)
        )
    }

    @Test func markdownFenceIsTreatedAsText() throws {
        let result = CorrectionResult(action: .commit, text: "ok ```fenced```", risk: .low)
        try CorrectionValidator.validate(result, for: makeRequest(raw: "ok"))
    }

    @Test func thinkTagIsTreatedAsText() throws {
        let result = CorrectionResult(action: .commit, text: "ok <think>internal</think>", risk: .low)
        try CorrectionValidator.validate(result, for: makeRequest(raw: "ok"))
    }

    @Test func jsonLookingTextIsTreatedAsText() throws {
        let result = CorrectionResult(action: .commit, text: "{\"a\":1}", risk: .low)
        try CorrectionValidator.validate(result, for: makeRequest(raw: "ok"))
    }

    @Test func parseAndValidateTreatsRawOutputAsText() throws {
        let raw = "{\"action\":\"commit\",\"text\":\"hello world\",\"risk\":\"low\"}"
        let result = try CorrectionValidator.parseAndValidate(rawOutput: raw, for: makeRequest(raw: "hi there"))
        #expect(result.action == .commit)
        #expect(result.text == raw)
        #expect(result.risk == .low)
    }

    @Test func parseTextOnlyJSONIsNotSpecial() throws {
        let raw = "{\"text\":\"hello world\"}"
        let result = try CorrectionValidator.parseAndValidate(rawOutput: raw, for: makeRequest(raw: "hi there"))
        #expect(result.action == .commit)
        #expect(result.text == raw)
        #expect(result.risk == .low)
    }

    @Test func parseKeepsThinkBlockAsText() throws {
        let raw = "<think>let me think</think>\n{\"action\":\"commit\",\"text\":\"ok\",\"risk\":\"low\"}"
        let result = try CorrectionValidator.parseAndValidate(rawOutput: raw, for: makeRequest(raw: "ok"))
        #expect(result.text == raw)
    }

    @Test func parseKeepsFencedJSONAsText() throws {
        let raw = "```json\n{\"action\":\"commit\",\"text\":\"ok\",\"risk\":\"low\"}\n```"
        let result = try CorrectionValidator.parseAndValidate(rawOutput: raw, for: makeRequest(raw: "ok"))
        #expect(result.text == raw)
    }

    // MARK: - Helper

    private func makeRequest(raw: String, correctionMode: CorrectionMode = .polishPlus) -> CorrectionRequest {
        CorrectionRequest(
            correctionMode: correctionMode,
            frontmostAppName: nil, frontmostBundleID: nil,
            appCategory: .unknown, languageIDs: ["en-US"],
            rawTranscript: raw,
            userDictionary: []
        )
    }
}
