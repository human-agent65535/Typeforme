import Foundation

enum LocaleTextNormalizer {
    static func normalize(_ text: String, languageIDs: [String]) -> String {
        switch ASRLanguageSelection.scriptPreference(for: languageIDs) {
        case .simplified:
            return VerbatimSpanMask.transforming(text) {
                transformHanRuns($0, using: "Hant-Hans")
            }
        case .traditional:
            return VerbatimSpanMask.transforming(text) {
                transformHanRuns($0, using: "Hans-Hant")
            }
        case .preserve:
            return text
        }
    }

    static func normalize(_ text: String, locale: String) -> String {
        normalize(text, languageIDs: ASRLanguageSelection.parse(locale))
    }

    static func promptInstruction(for languageIDs: [String]) -> String {
        let languageNames = ASRLanguageSelection.displayNames(for: languageIDs).joined(separator: ", ")
        let languageScope = "Expected: \(languageNames). Preserve code-switching; do not translate."
        switch ASRLanguageSelection.scriptPreference(for: languageIDs) {
        case .simplified:
            return languageScope + " Chinese script: Simplified."
        case .traditional:
            return languageScope + " Chinese script: Traditional."
        case .preserve:
            return languageScope + " Preserve detected Chinese script."
        }
    }

    static func promptInstruction(for locale: String) -> String {
        promptInstruction(for: ASRLanguageSelection.parse(locale))
    }

    static func languageStyleGuidance(for languageIDs: [String]) -> String {
        let names = ASRLanguageSelection.displayNames(for: languageIDs).joined(separator: ", ")
        return "Language style guidance: for \(names), use natural contemporary wording for each detected language; preserve language-specific diacritics, accents, native scripts, casing, acronyms, product names, code, and proper nouns; avoid archaic, literary, or word-for-word calques unless the surrounding text clearly requires that style."
    }

    private static func transform(_ text: String, using transformName: String) -> String {
        let transform = StringTransform(rawValue: transformName)
        return (text as NSString).applyingTransform(transform, reverse: false) ?? text
    }

    private static func transformHanRuns(_ text: String, using transformName: String) -> String {
        var output = ""
        var run = ""
        var runContainsKana = false

        func flushRun() {
            guard !run.isEmpty else { return }
            output += runContainsKana ? run : transform(run, using: transformName)
            run = ""
            runContainsKana = false
        }

        for character in text {
            let scalars = character.unicodeScalars
            if scalars.contains(where: { UnicodeScriptClassifier.isHanBroad($0) || UnicodeScriptClassifier.isKana($0) }) {
                run.append(character)
                if scalars.contains(where: UnicodeScriptClassifier.isKana) {
                    runContainsKana = true
                }
            } else {
                flushRun()
                output.append(character)
            }
        }
        flushRun()
        return output
    }

}
