import Foundation

enum OpenAICompatibleNoThinkProfile: Equatable {
    case none
    case deepSeekV4
    case qwen
}

enum OpenAICompatibleReasoningHints {
    static func noThinkProfile(model: String, baseURL: String? = nil) -> OpenAICompatibleNoThinkProfile {
        if isDeepSeekV4Model(model) || isDeepSeekV4Endpoint(baseURL: baseURL, model: model) {
            return .deepSeekV4
        }
        if QwenPromptHints.prefersNoThink(model: model) {
            return .qwen
        }
        return .none
    }

    private static func isDeepSeekV4Model(_ model: String) -> Bool {
        model.lowercased().contains("deepseek-v4")
    }

    private static func isDeepSeekV4Endpoint(baseURL: String?, model: String) -> Bool {
        guard isDeepSeekV4Model(model),
              let host = host(from: baseURL)?.lowercased()
        else {
            return false
        }
        return host == "api.deepseek.com" || host.hasSuffix(".deepseek.com")
    }

    private static func host(from value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if let host = URLComponents(string: trimmed)?.host {
            return host
        }
        return URLComponents(string: "https://\(trimmed)")?.host
    }
}
