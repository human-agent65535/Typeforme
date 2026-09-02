import Foundation

/// Input separators belong to the draft, not to the model's pronunciation plan.
/// Technical spans are masked before splitting so spaces in code stay literal.
struct PinyinDraftLayout {
    let segments: [String]
    private let separators: [String]

    init(_ source: String) {
        let mask = VerbatimSpanMask(source, inputKind: .mixedTyping)
        var segments: [String] = []
        var separators = [""]
        var segment = ""
        for character in mask.maskedText {
            if character.isWhitespace {
                if !segment.isEmpty {
                    segments.append(segment)
                    separators.append("")
                    segment = ""
                }
                separators[separators.count - 1].append(character)
            } else {
                segment.append(character)
            }
        }
        if !segment.isEmpty {
            segments.append(segment)
            separators.append("")
        }
        self.segments = segments.map { segment in
            mask.entries.reduce(segment) { text, entry in
                text.replacingOccurrences(of: entry.token, with: entry.text)
            }
        }
        self.separators = separators
    }

    func replacement(
        from convertedSegments: [String],
        languageIDs: [String],
        punctuationPreference: PunctuationOutputPreference
    ) throws -> String {
        guard convertedSegments.count == segments.count else {
            throw TextEditValidationError.changedInputSegments
        }
        let hasExplicitSeparators = separators.contains { !$0.isEmpty }
        var output = separators[0]
        for (index, converted) in convertedSegments.enumerated() {
            let source = segments[index]
            try TextEditValidator.validateProtectedLiterals(in: converted, source: source)
            let sourceHasSentencePunctuation = VerbatimSpanMask(source, inputKind: .mixedTyping)
                .maskedText.contains { Self.sentencePunctuation.contains($0) }
            let normalized = VerbatimSpanMask.transforming(converted) { text in
                var text = text
                if hasExplicitSeparators && !sourceHasSentencePunctuation {
                    // The user already chose this segment's boundaries. Model
                    // punctuation must not introduce another clause inside it.
                    text.removeAll { Self.sentencePunctuation.contains($0) }
                    text = text.replacingOccurrences(of: #"[\r\n]+"#, with: " ", options: .regularExpression)
                }
                return text.replacingOccurrences(
                    of: #"(?<=\p{Han})[\p{Zs}\t]+(?=\p{Han})"#,
                    with: "",
                    options: .regularExpression
                )
            }
            let text = TranscriptPostProcessor.clean(
                LocaleTextNormalizer.normalize(normalized, languageIDs: languageIDs),
                languageIDs: languageIDs,
                preserveLineBreaks: true,
                punctuationPreference: punctuationPreference
            )
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TextEditValidationError.emptyText
            }
            try TextEditValidator.validateProtectedLiterals(in: text, source: source)
            output += text + separators[index + 1]
        }
        return output
    }

    private static let sentencePunctuation: Set<Character> = [
        ",", ".", "!", "?", ":", ";", "，", "。", "！", "？", "：", "；", "、", "…",
    ]
}
