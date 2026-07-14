import Foundation

/// Sends OpenAI-compatible chat-completion requests to the local llama-server.
/// On cold start `LlamaCppServerManager.ensureRunning` may take the configured
/// cold timeout; the actual chat call uses the configured request timeout.
final class EmbeddedLlamaCorrectorService: CorrectorService {
    let kind: CorrectionBackendKind
    private let server: LlamaCppServerManager
    private let contextSize: Int
    private let maxTokens: Int
    private let runtimeLease: CorrectorLlamaRuntimeLease
    private let activationBarrier: Task<Void, Never>?
    private let coldTimeoutMilliseconds: Int

    init(
        kind: CorrectionBackendKind,
        server: LlamaCppServerManager,
        contextSize: Int,
        maxTokens: Int,
        runtimeLease: CorrectorLlamaRuntimeLease,
        activationBarrier: Task<Void, Never>?,
        coldTimeoutMilliseconds: Int
    ) {
        self.kind = kind
        self.server = server
        self.contextSize = contextSize
        self.maxTokens = maxTokens
        self.runtimeLease = runtimeLease
        self.activationBarrier = activationBarrier
        self.coldTimeoutMilliseconds = coldTimeoutMilliseconds
    }

    func correct(_ request: CorrectionRequest, timeoutMs: Int) async throws -> CorrectorOutput {
        return try await CorrectorPipeline.correct(
            request: request,
            timeoutMs: timeoutMs,
            promptBudget: CorrectionPromptBudget(
                contextSize: contextSize,
                maxOutputTokens: maxTokens
            ),
            complete: { system, messages, timeoutMs in
                try await complete(
                    system: system,
                    messages: messages,
                    contextSize: contextSize,
                    maxTokens: maxTokens,
                    timeoutMs: timeoutMs
                )
            }
        )
    }

    func complete(system: String, messages: [CorrectorChatMessage], timeoutMs: Int) async throws -> String {
        try await complete(
            system: system,
            messages: messages,
            contextSize: contextSize,
            maxTokens: maxTokens,
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
            try await CorrectorLlamaActivationDeadline.wait(
                for: activationBarrier,
                timeoutMilliseconds: coldTimeoutMilliseconds
            )
            port = try await server.ensureRunning()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CorrectorError {
            throw error
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

/// Waiting for a predecessor runtime must not consume an unbounded request.
/// Each waiter owns only its deadline/cancellation; the shared retirement task
/// keeps running so timing out one request cannot strand later activations.
enum CorrectorLlamaActivationDeadline {
    static func wait(
        for barrier: Task<Void, Never>?,
        timeoutMilliseconds: Int
    ) async throws {
        guard let barrier else {
            try Task.checkCancellation()
            return
        }

        do {
            try await AsyncTaskBarrier.wait(
                for: barrier,
                timeoutNanoseconds: UInt64(max(1, timeoutMilliseconds)) * 1_000_000
            )
        } catch AsyncTaskBarrierError.timedOut {
            throw CorrectorError.timeout
        }
    }
}
