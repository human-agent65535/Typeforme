import Foundation

enum CorrectionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast = "fast"
    case clean = "clean"
    case polish = "polish"
    case polishPlus = "polish_plus"
    case structurePlus = "structure_plus"
    case formalPlus = "formal_plus"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast:              return "Fast"
        case .clean:             return "Clean"
        case .polish:            return "Polish"
        case .polishPlus:        return "Polish+"
        case .structurePlus:     return "Structure+"
        case .formalPlus:        return "Formal+"
        }
    }

    var usesRefine: Bool {
        self != .fast
    }

    var requiresQwenASR: Bool {
        self == .fast
    }

    static var promptEditableCases: [CorrectionMode] {
        allCases.filter(\.usesRefine)
    }

    var helpText: String {
        switch self {
        case .fast:
            return "Use Qwen ASR on Mac and insert the transcript directly. Requires Qwen ASR to be enabled and skips refine."
        case .clean:
            return "Fix punctuation, ASR mistakes, repeated words, and meaningless speech noise without rewriting."
        case .polish:
            return "Improve readability with limited wording changes while keeping the original structure and voice."
        case .polishPlus:
            return "Resolve the full transcript into polished, natural, logically clear text."
        case .structurePlus:
            return "Resolve the full transcript into an actionable note, request, or list."
        case .formalPlus:
            return "Resolve the full transcript into polished professional prose."
        }
    }
}
