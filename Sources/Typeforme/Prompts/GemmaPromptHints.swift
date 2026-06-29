import Foundation

enum GemmaPromptHints {
    static let noThinkAssistantPrefill = "<|channel>thought\n<channel|>"

    static func prefersNoThink(model: String) -> Bool {
        let lowercased = model.lowercased()
        return lowercased.contains("gemma-4") || lowercased.contains("gemma4")
    }

    static func openAIChatMessages(system: String, user: String, model: String) -> [[String: String]] {
        var messages = [
            ["role": "system", "content": system],
            ["role": "user", "content": user],
        ]
        if prefersNoThink(model: model) {
            messages.append(["role": "assistant", "content": noThinkAssistantPrefill])
        }
        return messages
    }
}
