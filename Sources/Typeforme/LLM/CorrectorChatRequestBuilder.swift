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
        body(
            model: model,
            system: system,
            messages: [.user(user)],
            maxTokens: maxTokens,
            baseURL: baseURL
        )
    }

    static func body(
        model: String,
        system: String,
        messages: [CorrectorChatMessage],
        maxTokens: Int,
        baseURL: String? = nil
    ) -> OpenAIChatCompletionRequest {
        let noThinkProfile = OpenAICompatibleReasoningHints.noThinkProfile(model: model, baseURL: baseURL)
        let messages = chatMessages(
            system: system,
            messages: messages,
            model: model,
            noThinkProfile: noThinkProfile
        )
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
        messages: [CorrectorChatMessage],
        model: String,
        noThinkProfile: OpenAICompatibleNoThinkProfile
    ) -> [OpenAIChatMessage] {
        if noThinkProfile == .qwen {
            return noThinkMessages(
                system: system,
                messages: messages,
                userTransform: { QwenPromptHints.userPrompt($0, model: model) },
                assistantPrefill: QwenPromptHints.noThinkAssistantPrefill
            )
        }
        if noThinkProfile == .gemma4 {
            return noThinkMessages(
                system: system,
                messages: messages,
                userTransform: { $0 },
                assistantPrefill: GemmaPromptHints.noThinkAssistantPrefill
            )
        }
        return [OpenAIChatMessage(role: "system", content: system)] + messages.map {
            OpenAIChatMessage(role: $0.role, content: $0.content)
        }
    }

    private static func noThinkMessages(
        system: String,
        messages: [CorrectorChatMessage],
        userTransform: (String) -> String,
        assistantPrefill: String
    ) -> [OpenAIChatMessage] {
        var output = [OpenAIChatMessage(role: "system", content: system)]
        let lastUserIndex = messages.lastIndex { $0.role == "user" }
        for (index, message) in messages.enumerated() {
            let shouldTransform = lastUserIndex.map { $0 == index } ?? false
            let content = shouldTransform ? userTransform(message.content) : message.content
            output.append(OpenAIChatMessage(role: message.role, content: content))
        }
        output.append(OpenAIChatMessage(role: "assistant", content: assistantPrefill))
        return output
    }
}
