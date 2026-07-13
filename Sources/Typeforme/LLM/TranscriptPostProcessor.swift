import Foundation
import os.lock

enum TranscriptPostProcessor {
    static func clean(
        _ text: String,
        languageIDs: [String],
        preserveLineBreaks: Bool = false,
        punctuationPreference: PunctuationOutputPreference = .normal
    ) -> String {
        let mask = VerbatimSpanMask(text)
        let preserveLineBreaks = preserveLineBreaks || mask.requiresLineBreakPreservation
        var out = mask.maskedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return out }

        out = normalizeLineBreaks(out)
        out = normalizeWhitespace(out, preserveLineBreaks: preserveLineBreaks)
        out = normalizeRepeatedPunctuation(out)
        out = normalizePunctuationSpacing(
            out,
            preserveLineBreaks: preserveLineBreaks
        )
        out = normalizeWhitespace(out, preserveLineBreaks: preserveLineBreaks)
        out = applyPunctuationPreference(
            out,
            punctuationPreference: punctuationPreference,
            preserveLineBreaks: preserveLineBreaks
        )
        out = normalizeWhitespace(out, preserveLineBreaks: preserveLineBreaks)
        return mask.restoring(
            out.trimmingCharacters(in: .whitespacesAndNewlines)
        ) ?? text
    }

    private static func normalizeRepeatedPunctuation(_ text: String) -> String {
        replaceRegexMatches(text, pattern: #"([,，])(?:\s*[,，])+"#) { groups in
            groups.first
        }
    }

    private static func normalizePunctuationSpacing(
        _ text: String,
        preserveLineBreaks: Bool
    ) -> String {
        let whitespace = preserveLineBreaks ? #"[ \t]+"# : #"\s+"#
        var out = regexReplace(text, pattern: "\(whitespace)([,，。.!?！？])", with: "$1")
        out = regexReplace(out, pattern: "([，。！？])\(whitespace)", with: "$1")
        return out
    }

    private static func normalizeWhitespace(_ text: String, preserveLineBreaks: Bool) -> String {
        guard preserveLineBreaks else {
            return regexReplace(text, pattern: #"\s+"#, with: " ")
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                regexReplace(String(line), pattern: #"[ \t]+"#, with: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
    }

    private static func normalizeLineBreaks(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func applyPunctuationPreference(
        _ text: String,
        punctuationPreference: PunctuationOutputPreference,
        preserveLineBreaks: Bool
    ) -> String {
        switch punctuationPreference {
        case .normal:
            return text
        case .english:
            return normalizeEnglishPunctuation(text, preserveLineBreaks: preserveLineBreaks)
        case .spaces:
            return replaceSentencePunctuationWithSpaces(text)
        }
    }

    private static func normalizeEnglishPunctuation(
        _ text: String,
        preserveLineBreaks: Bool
    ) -> String {
        var out = text
        let replacements: [(String, String)] = [
            ("，", ","), ("。", "."), ("！", "!"), ("？", "?"),
            ("：", ":"), ("；", ";"), ("、", ","),
            ("“", "\""), ("”", "\""), ("‘", "'"), ("’", "'"),
            ("（", "("), ("）", ")"), ("【", "["), ("】", "]"),
            ("《", "<"), ("》", ">"), ("…", "..."),
        ]

        let horizontalWhitespace = preserveLineBreaks ? #"[ \t]+"# : #"\s+"#
        out = regexReplace(out, pattern: "\(horizontalWhitespace)([,.;:!?，。！？：；、…])", with: "$1")
        out = regexReplace(
            out,
            pattern: #"([,.;:!?，。！？：；、…])(?=[\p{L}\p{N}\p{Co}（【《“‘\(\[<])"#,
            with: "$1 "
        )
        for (source, target) in replacements {
            out = out.replacingOccurrences(of: source, with: target)
        }
        return out
    }

    private static func replaceSentencePunctuationWithSpaces(_ text: String) -> String {
        let sentencePunctuation: Set<Character> = [
            ",", ".", "!", "?", ":", ";",
            "，", "。", "！", "？", "：", "；", "、", "…",
        ]
        return String(text.map { sentencePunctuation.contains($0) ? " " : $0 })
    }

    private static func regexReplace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = regex(for: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func replaceRegexMatches(
        _ text: String,
        pattern: String,
        transform: ([String]) -> String?
    ) -> String {
        guard let regex = regex(for: pattern) else { return text }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        var out = text
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: out) else { continue }
            var groups: [String] = []
            for index in 1..<match.numberOfRanges {
                let nsRange = match.range(at: index)
                guard nsRange.location != NSNotFound,
                      let range = Range(nsRange, in: out)
                else { continue }
                groups.append(String(out[range]))
            }
            guard let replacement = transform(groups) else { continue }
            out.replaceSubrange(matchRange, with: replacement)
        }
        return out
    }

    private static func regex(for pattern: String) -> NSRegularExpression? {
        if let cached = regexCache.withLock({ cache in cache[pattern] }) {
            return cached
        }

        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache.withLock { cache in
            cache[pattern] = compiled
        }
        return compiled
    }

    private static let regexCache = OSAllocatedUnfairLock(initialState: [String: NSRegularExpression]())
}
