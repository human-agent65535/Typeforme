import Foundation

enum TextEditValidationError: LocalizedError {
    case parseFailed(String)
    case emptyText
    case invalidAction
    case textTooLong(actual: Int, cap: Int)
    case containsMarkupOrJSON
    case changedPinyin
    case changedProtectedText

    var errorDescription: String? {
        switch self {
        case .parseFailed(let why): return "Parse failed: \(why)"
        case .emptyText: return "Empty edit result"
        case .invalidAction: return "Invalid edit action"
        case .textTooLong(let actual, let cap): return "Edit result too long (\(actual) > \(cap))"
        case .containsMarkupOrJSON: return "Edit result contains markup or JSON"
        case .changedPinyin: return "Pinyin syllables changed the typed input"
        case .changedProtectedText: return "Pinyin conversion changed a protected literal"
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
        // Literal comparison is sound for pinyin letters. Mixed input can have
        // equivalent readings such as 3 -> san in the model's phonetic plan.
        if request.intent == .pinyinToChinese,
           hasOnlyPinyinLettersAndSeparators(request.targetText),
           let syllables = payload.pinyinSyllables {
            guard pinyinLetters(syllables) == pinyinLetters(request.targetText) else {
                throw TextEditValidationError.changedPinyin
            }
        }
        let result = TextEditResult(action: action, text: payload.text)
        if request.intent == .pinyinToChinese {
            var remainingLiterals = VerbatimSpanMask(result.text).entries[...]
            for literal in VerbatimSpanMask(request.targetText).entries {
                guard let match = remainingLiterals.firstIndex(where: { $0.text == literal.text }) else {
                    throw TextEditValidationError.changedProtectedText
                }
                remainingLiterals = remainingLiterals.suffix(from: remainingLiterals.index(after: match))
            }
        }
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
        case .pinyinToChinese:
            return max(32, request.targetText.count * 2)
        }
    }

    private struct TextEditPayload: Decodable {
        var action: TextEditAction?
        var text: String
        var pinyinSyllables: String?

        enum CodingKeys: String, CodingKey {
            case action
            case text
            case pinyinSyllables = "pinyin_syllables"
        }
    }

    private static func pinyinLetters(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func hasOnlyPinyinLettersAndSeparators(_ text: String) -> Bool {
        text.allSatisfy {
            ($0.isASCII && $0.isLetter) || $0.isWhitespace || $0 == "'" || $0 == "’"
        }
    }
}
