import Foundation

enum NumberOutputPreference: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic = "auto"
    case digits
    case words

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Auto"
        case .digits: return "Digits"
        case .words: return "Words"
        }
    }

    var helpText: String {
        switch self {
        case .automatic:
            return "Keep the current model behavior for numbers."
        case .digits:
            return "Prefer numerals such as 12, 3.5, and 2026 when the meaning is numeric."
        case .words:
            return "Prefer written number words when natural for the output language."
        }
    }

    var promptInstruction: String {
        switch self {
        case .automatic:
            return "natural"
        case .digits:
            return "prefer digits for numeric values"
        case .words:
            return "prefer words unless digits are exact tokens"
        }
    }

    static func normalized(_ raw: String?) -> NumberOutputPreference {
        guard let raw,
              let value = NumberOutputPreference(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        else { return .automatic }
        return value
    }
}

enum PunctuationOutputPreference: String, CaseIterable, Identifiable, Codable, Sendable {
    case normal
    case english
    case spaces

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .english: return "English punctuation"
        case .spaces: return "Spaces"
        }
    }

    var helpText: String {
        switch self {
        case .normal:
            return "Use natural punctuation for the output language."
        case .english:
            return "Use ASCII punctuation such as commas, periods, question marks, and colons."
        case .spaces:
            return "Replace sentence punctuation with spaces where possible."
        }
    }

    var promptInstruction: String {
        switch self {
        case .normal:
            return "natural"
        case .english:
            return "ASCII punctuation"
        case .spaces:
            return "spaces instead of sentence punctuation"
        }
    }

    static func normalized(_ raw: String?) -> PunctuationOutputPreference {
        guard let raw,
              let value = PunctuationOutputPreference(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        else { return .normal }
        return value
    }
}
