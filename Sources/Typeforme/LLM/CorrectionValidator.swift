import Foundation

enum CorrectionValidationError: LocalizedError {
    case emptyText
    case textTooLong(actual: Int, cap: Int)

    var errorDescription: String? {
        switch self {
        case .emptyText:                        return "Empty text on commit"
        case .textTooLong(let a, let c):        return "Output too long (\(a) > \(c))"
        }
    }
}

/// Treats model output as direct insertion text and enforces guardrails before commit.
enum CorrectionValidator {
    static func parseAndValidate(rawOutput: String, for request: CorrectionRequest) throws -> CorrectionResult {
        let result = CorrectionResult(
            action: .commit,
            text: rawOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            risk: .low
        )
        try validate(result, for: request)
        return result
    }

    static func validate(_ result: CorrectionResult, for request: CorrectionRequest) throws {
        // Keep a guardrail against hallucinated essays, but allow normal
        // expansion from punctuation, mixed-language spacing, and structured
        // correction modes.
        let cap = maxOutputCharacters(for: request)
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw CorrectionValidationError.emptyText
        }
        if result.text.count > cap {
            throw CorrectionValidationError.textTooLong(actual: result.text.count, cap: cap)
        }
    }

    private static func maxOutputCharacters(for request: CorrectionRequest) -> Int {
        let baseline = ([request.rawTranscript] + request.asrHypotheses)
            .map(\.count)
            .max() ?? request.rawTranscript.count
        switch request.correctionMode {
        case .fast:
            return max(80, baseline)
        case .clean:
            return max(80, baseline * 3)
        case .polishPlus, .formalPlus:
            return max(140, baseline * 4)
        case .structurePlus:
            return max(180, baseline * 6)
        }
    }

}
