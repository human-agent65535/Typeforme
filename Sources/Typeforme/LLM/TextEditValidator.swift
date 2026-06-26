import Foundation

enum TextEditValidationError: LocalizedError {
    case parseFailed(String)
    case emptyText
    case invalidAction
    case textTooLong(actual: Int, cap: Int)
    case containsMarkupOrJSON

    var errorDescription: String? {
        switch self {
        case .parseFailed(let why): return "Parse failed: \(why)"
        case .emptyText: return "Empty edit result"
        case .invalidAction: return "Invalid edit action"
        case .textTooLong(let actual, let cap): return "Edit result too long (\(actual) > \(cap))"
        case .containsMarkupOrJSON: return "Edit result contains markup or JSON"
        }
    }
}

enum TextEditValidator {
    static func parseAndValidate(rawOutput: String, for request: TextEditRequest) throws -> TextEditResult {
        let payload: TextEditPayload = try ModelJSONOutputValidator.decodePayload(
            rawOutput: rawOutput,
            parseError: TextEditValidationError.parseFailed
        )

        let action = payload.action ?? .replaceTarget
        guard action == .replaceTarget else {
            throw TextEditValidationError.invalidAction
        }
        let result = TextEditResult(action: action, text: payload.text)
        try validate(result, for: request)
        return result
    }

    static func validate(_ result: TextEditResult, for request: TextEditRequest) throws {
        let cap = maxOutputCharacters(for: request)
        try ModelJSONOutputValidator.validateText(
            result.text,
            cap: cap,
            emptyError: TextEditValidationError.emptyText,
            tooLongError: { actual, cap in
                TextEditValidationError.textTooLong(actual: actual, cap: cap)
            },
            containsMarkupOrJSONError: TextEditValidationError.containsMarkupOrJSON
        )
    }

    private static func maxOutputCharacters(for request: TextEditRequest) -> Int {
        let baseline = max(request.targetText.count, request.spokenInstruction.count)
        switch request.intent {
        case .repairSelection:
            return max(80, baseline * 4)
        case .command:
            return max(160, baseline * 8)
        }
    }

    private struct TextEditPayload: Decodable {
        var action: TextEditAction?
        var text: String
    }
}
