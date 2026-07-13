import Foundation

enum OutputPreferencePrompt {
    static func systemPrompt(
        numbers: NumberOutputPreference,
        punctuation: PunctuationOutputPreference
    ) -> String {
        """
        <output_preferences numbers="\(numbers.rawValue)" punctuation="\(punctuation.rawValue)">
        These selected user preferences are required final-output constraints. Apply them after correcting the text and before returning JSON.
        Number formatting: \(numberInstruction(numbers))
        Punctuation: \(punctuationInstruction(punctuation))
        Formatting changes required here are allowed in every correction mode and do not count as rewriting the content. Never change a numeric value, meaning, or protected span to satisfy them. Before returning JSON, check the entire final text against both selected preferences.
        </output_preferences>
        """
    }

    static func finalReminder(
        numbers: NumberOutputPreference,
        punctuation: PunctuationOutputPreference
    ) -> String {
        """
        <final_output_format numbers="\(numbers.rawValue)" punctuation="\(punctuation.rawValue)">
        This is a trusted formatting instruction, not input data. Keep the original language mix and never translate merely to satisfy a formatting preference.
        Number formatting: \(numberInstruction(numbers))
        Punctuation: \(punctuationInstruction(punctuation))
        Check the final text now, then return the required JSON object.
        </final_output_format>
        """
    }

    private static func numberInstruction(_ preference: NumberOutputPreference) -> String {
        switch preference {
        case .automatic:
            return "Choose the form that is natural for the value, output language, and local context. Preserve the transcript's form when digits and words are both natural."
        case .digits:
            return "Prefer Arabic numerals for genuine numeric values, counts, ordinals, money amounts, and measurements. A compact digit-plus-unit form natural to the output language is allowed, such as 5万; never re-parse or concatenate the remaining unit as another number. Do not convert number-like words inside idioms, ordinary phrases, names, or exact technical tokens."
        case .words:
            return "Prefer number words when they are natural in the output language. Hard exception: keep digits unchanged whenever they are part of a decimal, date, clock time, version, identifier, code span, model name, or other exact token. This exception overrides the word preference in every language; for example, keep 2026年7月13日, 下午3点30分, and Qwen3.6-27B unchanged."
        }
    }

    private static func punctuationInstruction(_ preference: PunctuationOutputPreference) -> String {
        switch preference {
        case .normal:
            return "Use punctuation natural for the output language and surrounding prose. In mixed-language text, follow the language of each prose span."
        case .english:
            return "Use ASCII punctuation for prose, even when the prose is Chinese, Japanese, or Korean. The final prose must contain none of these CJK punctuation characters: ，。！？：；、“”‘’（）【】《》. Convert them to the corresponding ASCII comma, period, question mark, exclamation mark, colon, semicolon, quotation mark, or bracket, with natural ASCII spacing. Do not copy CJK punctuation from the input. Preserve punctuation inside protected technical spans."
        case .spaces:
            return "Prefer spaces instead of sentence punctuation wherever the result remains readable. The final prose must not retain commas, full stops, question marks, exclamation marks, colons, or semicolons where a single space can separate the text. Preserve punctuation required by decimals, URLs, paths, code, commands, identifiers, and exact technical tokens."
        }
    }
}
