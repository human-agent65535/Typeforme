import Foundation

/// Sends OpenAI-compatible chat-completion requests to the local llama-server.
/// On cold start `LlamaCppServerManager.ensureRunning` may take the configured
/// cold timeout; the actual chat call uses the configured request timeout.
final class EmbeddedLlamaCorrectorService: CorrectorService {
    let kind: CorrectionBackendKind
    private let server: LlamaCppServerManager

    init(kind: CorrectionBackendKind, server: LlamaCppServerManager) {
        self.kind = kind
        self.server = server
    }

    func correct(_ request: CorrectionRequest, timeoutMs: Int) async throws -> CorrectorOutput {
        let contextSize = AppSettings.correctionContextSize
        let maxOutputTokens = AppSettings.correctionMaxTokens
        return try await CorrectorPipeline.correct(
            request: request,
            timeoutMs: timeoutMs,
            promptBudget: CorrectionPromptBudget(
                contextSize: contextSize,
                maxOutputTokens: maxOutputTokens
            ),
            complete: { system, messages, timeoutMs in
                try await complete(
                    system: system,
                    messages: messages,
                    contextSize: contextSize,
                    maxTokens: maxOutputTokens,
                    timeoutMs: timeoutMs
                )
            }
        )
    }

    func complete(system: String, messages: [CorrectorChatMessage], timeoutMs: Int) async throws -> String {
        try await complete(
            system: system,
            messages: messages,
            contextSize: AppSettings.correctionContextSize,
            maxTokens: AppSettings.correctionMaxTokens,
            timeoutMs: timeoutMs
        )
    }

    private func complete(
        system: String,
        messages: [CorrectorChatMessage],
        contextSize: Int,
        maxTokens: Int,
        timeoutMs: Int
    ) async throws -> String {
        try Self.validatePromptCapacity(
            system: system,
            messages: messages,
            contextSize: contextSize,
            maxTokens: maxTokens
        )

        // Warmup uses the cold-timeout window from settings.
        let port: Int
        do {
            port = try await server.ensureRunning()
        } catch {
            throw CorrectorError.unavailable(error.localizedDescription)
        }

        let body = CorrectorChatRequestBuilder.body(
            model: "qwen3.5",
            system: system,
            messages: messages,
            maxTokens: maxTokens
        )
        do {
            return try await OpenAICompatibleClient.chatCompletionContent(
                endpoint: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
                request: body,
                timeoutMs: timeoutMs
            ) { [server] in
                await server.stop()
            }
        } catch let error as OpenAICompatibleClientError {
            throw error.correctorError
        }
    }

    static func validatePromptCapacity(
        system: String,
        messages: [CorrectorChatMessage],
        contextSize: Int,
        maxTokens: Int
    ) throws {
        let budget = CorrectionPromptBudget(
            contextSize: contextSize,
            maxOutputTokens: maxTokens
        )
        guard budget.canFit(system: system, messages: messages) else {
            let estimated = budget.estimatedInputTokens(system: system, messages: messages)
            throw CorrectorError.requestFailed(
                CorrectionPromptBudget.chatCapacityFailurePrefix + " "
                    + "(estimated input \(estimated), output \(max(0, maxTokens)), "
                    + "context \(max(0, contextSize)))"
            )
        }
    }
}
