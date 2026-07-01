import Testing
@testable import Typeforme

@Suite("CorrectorPipeline")
struct CorrectorPipelineTests {
    @Test func formatErrorUsesFullContextRewrap() async throws {
        let stub = CompletionStub(outputs: [
            "hello world",
            "{\"decision\":\"rewrap\",\"text\":\"hello world\"}",
        ])
        let request = makeRequest(raw: "hello world")

        let output = try await CorrectorPipeline.correct(
            request: request,
            timeoutMs: 1_000,
            complete: { system, messages, timeoutMs in
                try await stub.complete(system: system, messages: messages, timeoutMs: timeoutMs)
            }
        )
        let requests = await stub.requests

        #expect(output.result.text == "hello world")
        #expect(output.debugTrace.rawModelOutput == "hello world")
        #expect(output.debugTrace.formatRepairAttempted)
        #expect(output.debugTrace.formatRepairDecision == "rewrap")
        #expect(requests.count == 2)
        #expect(requests[1].messages.count == 3)
        #expect(requests[1].messages[0].role == "user")
        #expect(requests[1].messages[1] == .assistant("hello world"))
        #expect(requests[1].messages[2].content.contains("Rewrap the same intended final transcript"))
    }

    @Test func lengthSignalUsesVerifierAcceptWithoutRewrite() async throws {
        let candidate = String(repeating: "x", count: 40)
        let stub = CompletionStub(outputs: [
            "{\"text\":\"\(candidate)\"}",
            "{\"decision\":\"accept\",\"reason_code\":\"ok\",\"text\":\"\(candidate)\"}",
        ])
        let request = makeRequest(raw: "short", correctionMode: .clean)

        let output = try await CorrectorPipeline.correct(
            request: request,
            timeoutMs: 1_000,
            complete: { system, messages, timeoutMs in
                try await stub.complete(system: system, messages: messages, timeoutMs: timeoutMs)
            }
        )
        let requests = await stub.requests

        #expect(output.result.text == candidate)
        #expect(output.debugTrace.validationSignal?.contains("Output too long") == true)
        #expect(output.debugTrace.verifierAttempted)
        #expect(output.debugTrace.verifierDecision == "accept")
        #expect(requests.count == 2)
        #expect(requests[1].messages[1].content == "{\"text\":\"\(candidate)\"}")
        #expect(requests[1].messages[2].content.contains("You are checking, not editing"))
    }

    @Test func repeatedCandidateCanBeVerifierReplaced() async throws {
        let candidate = "今天需要检查这个问题。今天需要检查这个问题。"
        let replacement = "今天需要检查这个问题。"
        let stub = CompletionStub(outputs: [
            "{\"text\":\"\(candidate)\"}",
            "{\"decision\":\"replace\",\"reason_code\":\"minimal_fix\",\"text\":\"\(replacement)\"}",
        ])
        let request = makeRequest(raw: "今天需要检查这个问题")

        let output = try await CorrectorPipeline.correct(
            request: request,
            timeoutMs: 1_000,
            complete: { system, messages, timeoutMs in
                try await stub.complete(system: system, messages: messages, timeoutMs: timeoutMs)
            }
        )

        #expect(output.result.text == replacement)
        #expect(output.debugTrace.verifierAttempted)
        #expect(output.debugTrace.verifierDecision == "replace")
        #expect(output.debugTrace.verifierText == replacement)
    }

    private func makeRequest(raw: String, correctionMode: CorrectionMode = .polishPlus) -> CorrectionRequest {
        CorrectionRequest(
            correctionMode: correctionMode,
            frontmostAppName: nil,
            frontmostBundleID: nil,
            appCategory: .unknown,
            languageIDs: ["zh-CN", "en-US"],
            rawTranscript: raw,
            userDictionary: []
        )
    }
}

private actor CompletionStub {
    struct Request: Sendable {
        let system: String
        let messages: [CorrectorChatMessage]
        let timeoutMs: Int
    }

    private var outputs: [String]
    private(set) var requests: [Request] = []

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func complete(system: String, messages: [CorrectorChatMessage], timeoutMs: Int) throws -> String {
        requests.append(Request(system: system, messages: messages, timeoutMs: timeoutMs))
        guard !outputs.isEmpty else {
            throw CorrectorError.requestFailed("no stub output")
        }
        return outputs.removeFirst()
    }
}
