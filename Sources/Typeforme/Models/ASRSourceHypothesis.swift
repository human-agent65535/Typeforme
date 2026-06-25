import Foundation

struct ASRSourceHypothesis: Codable, Sendable, Equatable {
    static let unattributedSource = "unattributed"

    let source: String
    let text: String

    init(source: String, text: String) {
        self.source = Self.normalizedSourceID(source)
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fromModelOutputs(
        _ outputs: [ASRTranscriptModelOutput],
        fallbackTexts: [String?] = []
    ) -> [ASRSourceHypothesis] {
        let hypotheses = outputs.compactMap { output -> ASRSourceHypothesis? in
            guard output.status == "ok",
                  let text = output.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return nil }
            return ASRSourceHypothesis(source: sourceID(forProvider: output.provider), text: text)
        }
        return normalized(hypotheses, fallbackTexts: fallbackTexts)
    }

    static func normalized(
        _ hypotheses: [ASRSourceHypothesis],
        fallbackTexts: [String?] = []
    ) -> [ASRSourceHypothesis] {
        var seen = Set<String>()
        var result: [ASRSourceHypothesis] = []

        for hypothesis in hypotheses {
            let text = hypothesis.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            result.append(ASRSourceHypothesis(source: hypothesis.source, text: text))
        }

        for candidate in fallbackTexts {
            let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            result.append(ASRSourceHypothesis(source: unattributedSource, text: text))
        }

        return result
    }

    static func sourceID(forProvider provider: String) -> String {
        switch provider {
        case "qwen3-asr-llama":
            return "qwen"
        case "apple-speech":
            return "apple_speech"
        case "nvidia-nemotron-asr":
            return "nvidia_nemotron"
        default:
            return normalizedSourceID(provider)
        }
    }

    private static func normalizedSourceID(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? unattributedSource : trimmed
    }
}
