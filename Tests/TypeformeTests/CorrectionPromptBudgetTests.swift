import Foundation
import Testing
@testable import Typeforme

@Suite("Correction prompt budget")
struct CorrectionPromptBudgetTests {
    @Test func representativeThreeSourceRequestFits2048AndCompactsStatuses() throws {
        let raw = "打开 https://example.com/api/v1 然后检查 /users 这个 path"
        let request = CorrectionRequest(
            correctionMode: .clean,
            frontmostAppName: "Notes",
            frontmostBundleID: "com.apple.Notes",
            appCategory: .document,
            languageIDs: ["zh-CN", "en-US"],
            rawTranscript: raw,
            contextBefore: "上一句正在讨论接口返回值。",
            contextAfter: "下一句准备说明部署计划。",
            userDictionary: [],
            audioDurationMs: 2_400,
            sourceHypotheses: [
                ASRSourceHypothesis(source: "qwen", text: raw),
                ASRSourceHypothesis(source: "nvidia_nemotron", text: "打开 example.com API 然后检查 users path"),
                ASRSourceHypothesis(source: "apple_speech", text: ""),
            ]
        )
        let budget = CorrectionPromptBudget(contextSize: 2_048, maxOutputTokens: 128)
        let system = representativeCompactSystem

        let user = try PromptBuilder.budgetedUserPrompt(for: request, system: system, budget: budget)
        let input = try inputJSONObject(user)
        let hypotheses = try #require(input["asr_hypotheses"] as? [[String: Any]])

        #expect(budget.canFit(system: system, user: user))
        #expect(input["raw_transcript"] as? String == raw)
        #expect(hypotheses.count == 3)
        #expect(hypotheses[0]["source"] as? String == "qwen")
        #expect(hypotheses[0]["matches_raw_transcript"] as? Bool == true)
        #expect(hypotheses[0]["text"] == nil)
        #expect(hypotheses[1]["text"] as? String == "打开 example.com API 然后检查 users path")
        #expect(hypotheses[2]["source"] as? String == "apple_speech")
        #expect(hypotheses[2]["completed_empty"] as? Bool == true)
        #expect(hypotheses[2]["text"] == nil)
    }

    @Test func rawTranscriptIsByteForByteUnchanged() throws {
        let raw = "  第一行\r\n第二行\\path🙂\u{0000}  "
        let request = makeRequest(raw: raw)
        let budget = CorrectionPromptBudget(contextSize: 2_048, maxOutputTokens: 16)

        let user = try PromptBuilder.budgetedUserPrompt(
            for: request,
            system: representativeCompactSystem,
            budget: budget
        )
        let input = try inputJSONObject(user)
        let decodedRaw = try #require(input["raw_transcript"] as? String)

        #expect(Array(decodedRaw.utf8) == Array(raw.utf8))
    }

    @Test func constrainedContextKeepsCursorNearestSuffixAndPrefix() throws {
        let before = "FAR_BEFORE_" + String(repeating: "甲", count: 1_500) + "_NEAR_BEFORE"
        let after = "NEAR_AFTER_" + String(repeating: "乙", count: 1_500) + "_FAR_AFTER"
        let request = CorrectionRequest(
            correctionMode: .clean,
            frontmostAppName: "Large Context App",
            frontmostBundleID: "com.example.large-context",
            appCategory: .document,
            languageIDs: ["zh-CN"],
            rawTranscript: "我刚和样例佳确认了这个 bug",
            contextBefore: before,
            contextAfter: after,
            userDictionary: [DictionaryEntry(type: "person", surface: "样例甲")],
            sourceHypotheses: [
                ASRSourceHypothesis(source: "qwen", text: "我刚和样例佳确认了这个 bug"),
                ASRSourceHypothesis(source: "apple_speech", text: "我刚和样例家确认了这个 bug"),
            ]
        )
        let budget = CorrectionPromptBudget(contextSize: 2_048, maxOutputTokens: 16)
        let system = String(repeating: "Bounded correction rule. ", count: 190)

        let user = try PromptBuilder.budgetedUserPrompt(for: request, system: system, budget: budget)
        let input = try inputJSONObject(user)
        let keptBefore = try #require(input["context_before"] as? String)
        let keptAfter = try #require(input["context_after"] as? String)
        let hypotheses = try #require(input["asr_hypotheses"] as? [[String: Any]])
        let context = try #require(input["context"] as? [String: Any])

        #expect(keptBefore != before)
        #expect(keptAfter != after)
        #expect(before.hasSuffix(keptBefore))
        #expect(after.hasPrefix(keptAfter))
        #expect(keptBefore.hasSuffix("_NEAR_BEFORE"))
        #expect(keptAfter.hasPrefix("NEAR_AFTER_"))
        #expect(hypotheses.contains { $0["text"] as? String == "我刚和样例家确认了这个 bug" })
        #expect(input["vocabulary_candidates"] == nil)
        #expect(context["app_name"] == nil)
        #expect(context["bundle_id"] == nil)
        #expect(context["app_category"] == nil)
        #expect(budget.canFit(system: system, user: user))
    }

    @Test func defaultBuilderKeepsFullExternalPayload() throws {
        let raw = "今天 ship 这个 feature"
        let request = CorrectionRequest(
            correctionMode: .clean,
            frontmostAppName: "Notes",
            frontmostBundleID: "com.apple.Notes",
            appCategory: .document,
            languageIDs: ["zh-CN", "en-US"],
            rawTranscript: raw,
            contextBefore: "FULL BEFORE",
            contextAfter: "FULL AFTER",
            userDictionary: [],
            sourceHypotheses: [
                ASRSourceHypothesis(source: "qwen", text: raw),
                ASRSourceHypothesis(source: "apple_speech", text: ""),
            ]
        )

        let input = try inputJSONObject(PromptBuilder.build(for: request).user)
        let hypotheses = try #require(input["asr_hypotheses"] as? [[String: Any]])

        #expect(input["context_before"] as? String == "FULL BEFORE")
        #expect(input["context_after"] as? String == "FULL AFTER")
        #expect(hypotheses[0]["text"] as? String == raw)
        #expect(hypotheses[0]["matches_raw_transcript"] == nil)
        #expect(hypotheses[1]["text"] as? String == "")
        #expect(hypotheses[1]["completed_empty"] == nil)
    }

    @Test func rawThatCannotFitFailsExplicitlyBeforeCompletion() async throws {
        let request = makeRequest(raw: String(repeating: "非常长的原始转写🙂", count: 2_000))
        let budget = CorrectionPromptBudget(contextSize: 2_048, maxOutputTokens: 128)

        do {
            _ = try await CorrectorPipeline.correct(
                request: request,
                timeoutMs: 1_000,
                promptBudget: budget,
                complete: { _, _, _ in
                    Issue.record("Completion must not run for an over-capacity request")
                    return #"{"text":"unexpected"}"#
                }
            )
            Issue.record("Expected requestFailed")
        } catch let error as CorrectorError {
            guard case .requestFailed(let message) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(message.contains("exceeds embedded context capacity"))
        }
    }

    @Test func appendedRepairMessagesFailPreflightBeforeServerStartup() throws {
        let messages: [CorrectorChatMessage] = [
            .user("short initial request"),
            .assistant(String(repeating: "model output ", count: 600)),
            .user(PromptBuilder.formatRepairPrompt(parseError: "no JSON object found")),
        ]

        do {
            try EmbeddedLlamaCorrectorService.validatePromptCapacity(
                system: representativeCompactSystem,
                messages: messages,
                contextSize: 2_048,
                maxTokens: 128
            )
            Issue.record("Expected requestFailed")
        } catch let error as CorrectorError {
            guard case .requestFailed(let message) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(message.hasPrefix(CorrectionPromptBudget.chatCapacityFailurePrefix))
        }
    }

    private func makeRequest(raw: String) -> CorrectionRequest {
        CorrectionRequest(
            correctionMode: .clean,
            frontmostAppName: nil,
            frontmostBundleID: nil,
            appCategory: .unknown,
            languageIDs: ["zh-CN", "en-US"],
            rawTranscript: raw,
            userDictionary: []
        )
    }

    /// Roughly the intended candidate system+mode size; payload tests should
    /// not couple their capacity to whichever prompt prose is under A/B review.
    private var representativeCompactSystem: String {
        String(repeating: "Faithful correction rule. ", count: 120)
    }

    private func inputJSONObject(_ prompt: String) throws -> [String: Any] {
        let opening = "<input_json>\n"
        let closing = "\n</input_json>"
        let start = try #require(prompt.range(of: opening)?.upperBound)
        let end = try #require(prompt.range(of: closing, range: start..<prompt.endIndex)?.lowerBound)
        let data = try #require(String(prompt[start..<end]).data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
