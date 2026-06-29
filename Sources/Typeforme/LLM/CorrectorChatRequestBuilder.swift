import Foundation

enum CorrectorChatRequestBuilder {
    static let temperature: Double = 0.2
    static let topP: Double = 0.8
    static let topK = 20
    static let minP: Double = 0.0
    static let presencePenalty: Double = 0.0
    static let repetitionPenalty: Double = 1.0

    static func body(
        model: String,
        system: String,
        user: String,
        maxTokens: Int,
        baseURL: String? = nil
    ) -> OpenAIChatCompletionRequest {
        let noThinkProfile = OpenAICompatibleReasoningHints.noThinkProfile(model: model, baseURL: baseURL)
        let messages = chatMessages(
            system: system,
            user: user,
            model: model,
            noThinkProfile: noThinkProfile
        )
            .map { message in
                OpenAIChatMessage(
                    role: message["role"] ?? "user",
                    content: message["content"] ?? ""
                )
            }
        let templateKwargs = noThinkProfile == .qwen || noThinkProfile == .gemma4
            ? OpenAIChatTemplateKwargs(enableThinking: false)
            : nil
        let thinking = noThinkProfile == .deepSeekV4
            ? OpenAIThinkingControl(type: "disabled")
            : nil
        return OpenAIChatCompletionRequest(
            model: model,
            messages: messages,
            temperature: temperature,
            topP: topP,
            topK: topK,
            minP: minP,
            presencePenalty: presencePenalty,
            repeatPenalty: repetitionPenalty,
            repetitionPenalty: repetitionPenalty,
            maxTokens: maxTokens,
            stream: false,
            thinking: thinking,
            reasoningEffort: nil,
            chatTemplateKwargs: templateKwargs
        )
    }

    private static func chatMessages(
        system: String,
        user: String,
        model: String,
        noThinkProfile: OpenAICompatibleNoThinkProfile
    ) -> [[String: String]] {
        if noThinkProfile == .qwen {
            return QwenPromptHints.openAIChatMessages(system: system, user: user, model: model)
        }
        if noThinkProfile == .gemma4 {
            return GemmaPromptHints.openAIChatMessages(system: system, user: user, model: model)
        }
        return [
            ["role": "system", "content": system],
            ["role": "user", "content": user],
        ]
    }
}
