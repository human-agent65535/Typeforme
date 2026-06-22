import Foundation

enum CorrectionValidationError: LocalizedError {
    case parseFailed(String)
    case emptyText
    case textTooLong(actual: Int, cap: Int)
    case containsMarkupOrJSON

    var errorDescription: String? {
        switch self {
        case .parseFailed(let why):             return "Parse failed: \(why)"
        case .emptyText:                        return "Empty text on commit"
        case .textTooLong(let a, let c):        return "Output too long (\(a) > \(c))"
        case .containsMarkupOrJSON:             return "Output contains markup or JSON"
        }
    }
}

/// Parses the model JSON payload and enforces output guardrails before commit.
enum CorrectionValidator {
    static func parseAndValidate(rawOutput: String, for request: CorrectionRequest) throws -> CorrectionResult {
        let payload: CorrectionPayload = try ModelJSONOutputValidator.decodePayload(
            rawOutput: rawOutput,
            parseError: CorrectionValidationError.parseFailed
        )
        let result = CorrectionResult(
            action: payload.action ?? .commit,
            text: payload.text,
            risk: payload.risk ?? .low
        )
        try validate(result, for: request)
        return result
    }

    static func validate(_ result: CorrectionResult, for request: CorrectionRequest) throws {
        // Keep a guardrail against hallucinated essays, but allow normal
        // expansion from punctuation, mixed-language spacing, and structured
        // correction modes.
        let cap = maxOutputCharacters(for: request)
        try ModelJSONOutputValidator.validateText(
            result.text,
            cap: cap,
            emptyError: CorrectionValidationError.emptyText,
            tooLongError: { actual, cap in
                CorrectionValidationError.textTooLong(actual: actual, cap: cap)
            },
            containsMarkupOrJSONError: CorrectionValidationError.containsMarkupOrJSON
        )
    }

    private static func maxOutputCharacters(for request: CorrectionRequest) -> Int {
        let baseline = ([request.rawTranscript] + request.asrHypotheses)
            .map(\.count)
            .max() ?? request.rawTranscript.count
        switch request.correctionMode {
        case .clean:
            return max(80, baseline * 3)
        case .polish:
            return max(100, baseline * 3)
        case .polishPlus, .formalPlus:
            return max(140, baseline * 4)
        case .structurePlus:
            return max(180, baseline * 6)
        }
    }

    private struct CorrectionPayload: Decodable {
        var action: CorrectionAction?
        var text: String
        var risk: CorrectionRisk?
    }
}
