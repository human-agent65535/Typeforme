import Testing
@testable import Typeforme

/// Rejection coverage for correction output validation.
@Suite("CorrectionValidator")
struct CorrectionValidatorTests {
    @Test func parsesStrictTextJSON() throws {
        let result = try CorrectionValidator.parseAndValidate(
            rawOutput: "{\"text\":\"hello world\"}",
            for: makeRequest(raw: "hello world")
        )

        #expect(result.action == .commit)
        #expect(result.text == "hello world")
        #expect(result.risk == .low)
    }

    @Test func rejectsDirectTextOutput() {
        #expect(throws: CorrectionValidationError.self) {
            _ = try CorrectionValidator.parseAndValidate(
                rawOutput: "hello world",
                for: makeRequest(raw: "hello world")
            )
        }
    }

    @Test func rejectsJSONWithExtraKeys() {
        #expect(throws: CorrectionValidationError.self) {
            _ = try CorrectionValidator.parseAndValidate(
                rawOutput: "{\"action\":\"commit\",\"text\":\"hello world\",\"risk\":\"low\"}",
                for: makeRequest(raw: "hello world")
            )
        }
    }

    @Test func rejectsSurroundingTextAroundJSON() {
        #expect(throws: CorrectionValidationError.self) {
            _ = try CorrectionValidator.parseAndValidate(
                rawOutput: "Here it is: {\"text\":\"hello world\"}",
                for: makeRequest(raw: "hello world")
            )
        }
    }

    @Test func parsesSingleFencedJSONOutput() throws {
        let result = try CorrectionValidator.parseAndValidate(
            rawOutput: "```json\n{\"text\":\"ok\"}\n```",
            for: makeRequest(raw: "ok")
        )

        #expect(result.text == "ok")
    }

    @Test func rejectsProseWithFencedJSONOutput() {
        #expect(throws: CorrectionValidationError.self) {
            _ = try CorrectionValidator.parseAndValidate(
                rawOutput: "Here it is:\n```json\n{\"text\":\"ok\"}\n```",
                for: makeRequest(raw: "ok")
            )
        }
    }

    @Test func rejectsThinkBlockOutput() {
        #expect(throws: CorrectionValidationError.self) {
            _ = try CorrectionValidator.parseAndValidate(
                rawOutput: "<think>internal</think>\n{\"text\":\"ok\"}",
                for: makeRequest(raw: "ok")
            )
        }
    }

    @Test func emptyTextIsValidNoCommitSignal() throws {
        let result = CorrectionResult(action: .commit, text: "  ", risk: .low)
        try CorrectionValidator.validate(result, for: makeRequest(raw: "hello"))
    }

    @Test func cleanLengthCapUsesRawTranscriptWithoutLargeFloor() throws {
        try CorrectionValidator.validate(
            CorrectionResult(action: .commit, text: String(repeating: "x", count: 26), risk: .low),
            for: makeRequest(raw: String(repeating: "a", count: 10), correctionMode: .clean)
        )
        #expect(throws: CorrectionValidationError.self) {
            try CorrectionValidator.validate(
                CorrectionResult(action: .commit, text: String(repeating: "x", count: 27), risk: .low),
                for: makeRequest(raw: String(repeating: "a", count: 10), correctionMode: .clean)
            )
        }
    }

    @Test func polishCanExpandWithinTighterCap() throws {
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

    @Test func repeatedSentenceTriggersValidationSignal() {
        #expect(throws: CorrectionValidationError.self) {
            try CorrectionValidator.validate(
                CorrectionResult(action: .commit, text: "今天需要检查这个问题。今天需要检查这个问题。", risk: .low),
                for: makeRequest(raw: "今天需要检查这个问题", correctionMode: .polishPlus)
            )
        }
    }

    @Test func concatenatedASRHypothesesTriggerValidationSignal() {
        let request = CorrectionRequest(
            correctionMode: .polishPlus,
            frontmostAppName: nil,
            frontmostBundleID: nil,
            appCategory: .unknown,
            languageIDs: ["zh-CN"],
            rawTranscript: "今天把这个功能发出去",
            userDictionary: [],
            asrHypotheses: [
                "今天把这个功能发出去",
                "今天把这个功能发去",
                "今天把这个功能发布出去",
            ]
        )

        #expect(throws: CorrectionValidationError.self) {
            try CorrectionValidator.validate(
                CorrectionResult(
                    action: .commit,
                    text: "今天把这个功能发出去。今天把这个功能发去。今天把这个功能发布出去。",
                    risk: .low
                ),
                for: request
            )
        }
    }

    private func makeRequest(raw: String, correctionMode: CorrectionMode = .polishPlus) -> CorrectionRequest {
        CorrectionRequest(
            correctionMode: correctionMode,
            frontmostAppName: nil,
            frontmostBundleID: nil,
            appCategory: .unknown,
            languageIDs: ["en-US"],
            rawTranscript: raw,
            userDictionary: []
        )
    }
}
