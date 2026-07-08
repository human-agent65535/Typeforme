import Foundation

enum CorrectionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast = "fast"
    case clean = "clean"
    case polishPlus = "polish_plus"
    case structurePlus = "structure_plus"
    case formalPlus = "formal_plus"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast:              return "Fast"
        case .clean:             return "Clean"
        case .polishPlus:        return "Polish+"
        case .structurePlus:     return "Structure+"
        case .formalPlus:        return "Formal+"
        }
    }

    var usesRefine: Bool {
        self != .fast
    }

    static var promptEditableCases: [CorrectionMode] {
        allCases.filter(\.usesRefine)
    }

    var helpText: String {
        switch self {
        case .fast:
            return "Insert the ASR transcript directly and skip refine. Uses the selected Fast ASR source only."
        case .clean:
            return "Fix punctuation, ASR mistakes, repeated words, and meaningless speech noise without rewriting."
        case .polishPlus:
            return "Rewrite into natural text while preserving the original intent, tone, and ambiguity."
        case .structurePlus:
            return "Restructure the transcript into an actionable note, request, or list while preserving intent."
        case .formalPlus:
            return "Rewrite into professional prose while preserving intent."
        }
    }
}
