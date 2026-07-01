import Foundation

enum CorrectionValidationError: LocalizedError {
    case parseFailed(String)
    case emptyText
    case textTooLong(actual: Int, cap: Int)
    case containsMarkupOrJSON
    case repeatedOutput
    case concatenatedASRHypotheses

    var errorDescription: String? {
        switch self {
        case .parseFailed(let why):              return "Parse failed: \(why)"
        case .emptyText:                        return "Empty text on commit"
        case .textTooLong(let a, let c):        return "Output too long (\(a) > \(c))"
        case .containsMarkupOrJSON:             return "Correction text contains markup or JSON"
        case .repeatedOutput:                   return "Correction text repeats the same content"
        case .concatenatedASRHypotheses:        return "Correction text appears to concatenate ASR hypotheses"
        }
    }
}

/// Parses the correction JSON contract and enforces guardrails before commit.
enum CorrectionValidator {
    static func parseAndValidate(rawOutput: String, for request: CorrectionRequest) throws -> CorrectionResult {
        let result = try parse(rawOutput: rawOutput)
        try validate(result, for: request)
        return result
    }

    static func parse(rawOutput: String) throws -> CorrectionResult {
        let payload = try decodePayload(rawOutput: rawOutput)
        let result = CorrectionResult(
            action: .commit,
            text: payload.text.trimmingCharacters(in: .whitespacesAndNewlines),
            risk: .low
        )
        return result
    }

    static func validate(_ result: CorrectionResult, for request: CorrectionRequest) throws {
        try validateForCommit(result)
        let cap = maxOutputCharacters(for: request)
        if result.text.count > cap {
            throw CorrectionValidationError.textTooLong(actual: result.text.count, cap: cap)
        }
        if looksRepeated(result.text) {
            throw CorrectionValidationError.repeatedOutput
        }
        if looksLikeConcatenatedASRHypotheses(result.text, request: request) {
            throw CorrectionValidationError.concatenatedASRHypotheses
        }
    }

    static func validateForCommit(_ result: CorrectionResult) throws {
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw CorrectionValidationError.emptyText
        }
        if result.text.contains("```") || result.text.contains("<think>") || result.text.contains("</think>") {
            throw CorrectionValidationError.containsMarkupOrJSON
        }
    }

    private static func maxOutputCharacters(for request: CorrectionRequest) -> Int {
        let baseline = request.rawTranscript.count
        switch request.correctionMode {
        case .fast:
            return baseline + 8
        case .clean:
            return Int((Double(baseline) * 1.4).rounded(.up)) + 12
        case .polishPlus, .formalPlus:
            return baseline * 2 + 24
        case .structurePlus:
            return baseline * 3 + 40
        }
    }

    private static func decodePayload(rawOutput: String) throws -> CorrectionPayload {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("```"),
              !trimmed.contains("<think>"),
              !trimmed.contains("</think>")
        else {
            throw CorrectionValidationError.parseFailed("output contains markup")
        }
        guard let jsonString = ModelOutputCleaner.extractFirstJSONObject(trimmed) else {
            throw CorrectionValidationError.parseFailed("no JSON object found")
        }
        guard jsonString == trimmed else {
            throw CorrectionValidationError.parseFailed("output must contain exactly one JSON object")
        }
        guard let data = jsonString.data(using: .utf8) else {
            throw CorrectionValidationError.parseFailed("not utf-8")
        }
        do {
            return try BridgeJSON.decode(CorrectionPayload.self, from: data)
        } catch {
            throw CorrectionValidationError.parseFailed(error.localizedDescription)
        }
    }

    private static func looksRepeated(_ text: String) -> Bool {
        let parts = text
            .split(whereSeparator: { character in
                character == "\n" || "。！？!?.".contains(character)
            })
            .map { comparableText(String($0)) }
            .filter { $0.count >= 8 }
        guard parts.count >= 2 else { return false }
        var counts: [String: Int] = [:]
        for part in parts {
            counts[part, default: 0] += 1
            if counts[part, default: 0] >= 2 {
                return true
            }
        }
        return false
    }

    private static func looksLikeConcatenatedASRHypotheses(_ text: String, request: CorrectionRequest) -> Bool {
        let hypotheses = request.sourceHypotheses
            .map(\.text)
            .isEmpty ? request.asrHypotheses : request.sourceHypotheses.map(\.text)
        let normalizedOutput = comparableText(text)
        var matches = Set<String>()
        for hypothesis in hypotheses {
            let normalized = comparableText(hypothesis)
            guard normalized.count >= 8 else { continue }
            if normalizedOutput.contains(normalized) {
                matches.insert(normalized)
            }
        }
        return matches.count >= 2
    }

    private static func comparableText(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .filter { character in
                character.isLetter || character.isNumber
            }
            .map(String.init)
            .joined()
    }

    private struct CorrectionPayload: Decodable {
        var text: String

        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: DynamicCodingKey.self).allKeys.map(\.stringValue)
            guard keys == ["text"] else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "expected only text key"
                    )
                )
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
        }

        private enum CodingKeys: String, CodingKey {
            case text
        }
    }

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}
