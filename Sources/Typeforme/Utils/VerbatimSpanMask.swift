import Foundation

/// Temporarily hides syntax-bearing spans while prose normalization runs.
/// Restoration is fail-closed: if a transform drops, duplicates, or reorders a
/// marker, callers keep their original input instead of committing partial text.
struct VerbatimSpanMask {
    enum InputKind {
        case prose
        case mixedTyping
    }

    struct Entry: Equatable {
        let token: String
        let text: String
    }

    let originalText: String
    let maskedText: String
    let entries: [Entry]
    let markerPrefix: String

    var requiresLineBreakPreservation: Bool {
        entries.contains { $0.text.contains("\n") || $0.text.contains("\r") }
    }

    init(_ text: String, inputKind: InputKind = .prose) {
        originalText = text

        var salt = 0
        var prefix = Self.markerPrefix(salt: salt)
        while text.contains(prefix) {
            salt += 1
            prefix = Self.markerPrefix(salt: salt)
        }
        markerPrefix = prefix

        let ranges = Self.protectedRanges(in: text, inputKind: inputKind)
        let nsText = text as NSString
        entries = ranges.enumerated().map { index, range in
            Entry(
                token: "\(prefix)\(index)\u{E003}",
                text: nsText.substring(with: range)
            )
        }

        var masked = text
        for (range, entry) in zip(ranges, entries).reversed() {
            guard let swiftRange = Range(range, in: masked) else { continue }
            masked.replaceSubrange(swiftRange, with: entry.token)
        }
        maskedText = masked
    }

    func restoring(_ transformed: String) -> String? {
        guard Self.occurrenceCount(of: markerPrefix, in: transformed) == entries.count else {
            return nil
        }

        var previousEnd = transformed.startIndex
        for entry in entries {
            let matches = Self.ranges(of: entry.token, in: transformed)
            guard matches.count == 1, let match = matches.first,
                  match.lowerBound >= previousEnd
            else {
                return nil
            }
            previousEnd = match.upperBound
        }

        var restored = transformed
        for entry in entries {
            guard let range = restored.range(of: entry.token) else { return nil }
            restored.replaceSubrange(range, with: entry.text)
        }
        guard !restored.contains(markerPrefix) else { return nil }
        return restored
    }

    static func transforming(_ text: String, _ transform: (String) -> String) -> String {
        let mask = VerbatimSpanMask(text)
        return mask.restoring(transform(mask.maskedText)) ?? text
    }

    static func markerPrefix(salt: Int) -> String {
        "\u{E000}\u{E001}\(salt)\u{E002}"
    }

    private static func protectedRanges(in text: String, inputKind: InputKind) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        var ranges = fencedCodeRanges(in: text)
        ranges.append(contentsOf: uriRanges(in: text, fullRange: fullRange))

        var patterns = [
            // Inline code with matching backtick delimiter length.
            #"(?<!`)(`+)[^\n]*?\1(?!`)"#,
            // An unmatched inline delimiter protects through the end of line.
            #"(?m)(?<!`)(`+)[^`\n]*$"#,
            // Quoted and unquoted POSIX paths, including escaped spaces.
            #"(?:\"(?:~/|\./|\.\./|/)[^\"\n]+\"|'(?:~/|\./|\.\./|/)[^'\n]+')"#,
            #"(?<![A-Za-z0-9_])(?:~/|\./|\.\./|/)(?:\\.|[A-Za-z0-9._~%+\-@/])+"#,
            // Windows drive and UNC paths.
            #"(?i)(?<![A-Za-z0-9_])(?:[A-Z]:\\|\\\\)(?:\\.|[A-Za-z0-9._~%+\-@\\])+"#,
            // Standalone query strings and assignments.
            #"(?<![A-Za-z0-9_])(?:\?[A-Za-z0-9._~%+\-]+=[A-Za-z0-9._~%+\-/?#&=,:;!]+|[A-Za-z_][A-Za-z0-9_.\-]*=[A-Za-z0-9._~%+\-/?#&=,:;!]+)"#,
            // Common syntax-bearing literals.
            #"\{[^{}\n]*[:=][^{}\n]*\}"#,
            #"\[[^\[\]\n]*[:=][^\[\]\n]*\]"#,
            #"\b[A-Za-z_][A-Za-z0-9_.]*\([^()\n]*\)"#,
            #"(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b"#,
            #"(?m)^[ \t]{0,3}\d+[.)](?=[ \t]+)"#,
            #"(?<![A-Za-z0-9_])--?[A-Za-z0-9][A-Za-z0-9_\-]*(?:=[^\s，。；！？、：]+)?"#,
            #"(?<![A-Za-z0-9_])(?:[A-Za-z_][A-Za-z0-9_.]*|\d+(?:\.\d+)?)(?:!=|==)(?:[A-Za-z_][A-Za-z0-9_.]*|\d+(?:\.\d+)?)(?![A-Za-z0-9_])"#,
            // Preserve a quoted argument following a CLI flag as one span.
            #"--?[A-Za-z0-9][A-Za-z0-9_\-]*\s+(?:\"[^\"\n]*\"|'[^'\n]*')"#,
        ]

        switch inputKind {
        case .prose:
            patterns += [
                #"(?<![A-Za-z0-9_])(?:[A-Za-z_][A-Za-z0-9_\-]*\.)+[A-Za-z0-9_\-]+(?![A-Za-z0-9_])"#,
                #"(?<![A-Za-z0-9_])\d{1,3}(?:,\d{3})+(?:\.\d+)?(?![A-Za-z0-9_])"#,
                #"(?<![A-Za-z0-9_])\d+(?:\.\d+)+(?![A-Za-z0-9_])"#,
                #"(?<![A-Za-z0-9_])\d+:\d+(?::\d+)?(?![A-Za-z0-9_])"#,
            ]
        case .mixedTyping:
            // Joined pinyin can touch a decimal on both sides. A digit after
            // the dot is a numeric boundary, not a dotted prose identifier.
            patterns += [
                #"(?<![A-Za-z0-9_])(?:[A-Za-z_][A-Za-z0-9_\-]*\.)+[A-Za-z_][A-Za-z0-9_\-]*(?![A-Za-z0-9_])"#,
                #"(?<!\d)\d{1,3}(?:,\d{3})+(?:\.\d+)?(?!\d)"#,
                #"(?<!\d)\d+(?:\.\d+)+(?!\d)"#,
                #"(?<!\d)\d+:\d+(?::\d+)?(?!\d)"#,
                #"(?<!\d)\d{4}[-/]\d{1,2}[-/]\d{1,2}(?!\d)"#,
                #"(?<!\d)\d{4}年\d{1,2}月\d{1,2}日"#,
                #"(?<!\d)\d{1,2}点\d{1,2}分"#,
            ]
        }

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            ranges.append(contentsOf: regex.matches(in: text, range: fullRange).map(\.range))
        }
        return mergedOverlappingRanges(ranges)
    }

    private static func uriRanges(in text: String, fullRange: NSRange) -> [NSRange] {
        let pattern = #"(?i)(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9+.\-]*://[^\s`\"'“”‘’<>\u3000，。；！？、：]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: fullRange).compactMap { match in
            trimmedURIRange(match.range, in: nsText)
        }
    }

    private static func trimmedURIRange(_ range: NSRange, in text: NSString) -> NSRange? {
        let candidate = text.substring(with: range)
        var characters = Array(candidate)
        let openParentheses = characters.count { $0 == "(" }
        var closeParentheses = characters.count { $0 == ")" }
        let openBrackets = characters.count { $0 == "[" }
        var closeBrackets = characters.count { $0 == "]" }
        let openBraces = characters.count { $0 == "{" }
        var closeBraces = characters.count { $0 == "}" }

        while let last = characters.last {
            if last == "." || last == "!" || last == ";" {
                characters.removeLast()
                continue
            }
            if last == ")" && closeParentheses > openParentheses {
                characters.removeLast()
                closeParentheses -= 1
                continue
            }
            if last == "]" && closeBrackets > openBrackets {
                characters.removeLast()
                closeBrackets -= 1
                continue
            }
            if last == "}" && closeBraces > openBraces {
                characters.removeLast()
                closeBraces -= 1
                continue
            }
            break
        }
        let length = String(characters).utf16.count
        return length > 0 ? NSRange(location: range.location, length: length) : nil
    }

    private static func fencedCodeRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        guard nsText.length > 0 else { return [] }

        struct OpenFence {
            let character: Character
            let count: Int
            let start: Int
        }

        var ranges: [NSRange] = []
        var openFence: OpenFence?
        var location = 0
        while location < nsText.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            nsText.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            let line = nsText.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))

            if let activeFence = openFence {
                if isClosingFence(line, character: activeFence.character, minimumCount: activeFence.count) {
                    ranges.append(NSRange(location: activeFence.start, length: lineEnd - activeFence.start))
                    openFence = nil
                }
            } else if let descriptor = openingFence(in: line) {
                openFence = OpenFence(
                    character: descriptor.character,
                    count: descriptor.count,
                    start: lineStart
                )
            }

            guard lineEnd > location else { break }
            location = lineEnd
        }

        if let openFence {
            ranges.append(NSRange(location: openFence.start, length: nsText.length - openFence.start))
        }
        return ranges
    }

    private static func openingFence(in line: String) -> (character: Character, count: Int)? {
        let characters = Array(line)
        var index = 0
        while index < characters.count, index < 3, characters[index] == " " {
            index += 1
        }
        guard index < characters.count,
              characters[index] == "`" || characters[index] == "~"
        else {
            return nil
        }
        let character = characters[index]
        var count = 0
        while index + count < characters.count, characters[index + count] == character {
            count += 1
        }
        return count >= 3 ? (character, count) : nil
    }

    private static func isClosingFence(
        _ line: String,
        character: Character,
        minimumCount: Int
    ) -> Bool {
        let characters = Array(line)
        var index = 0
        while index < characters.count, index < 3, characters[index] == " " {
            index += 1
        }
        var count = 0
        while index + count < characters.count, characters[index + count] == character {
            count += 1
        }
        guard count >= minimumCount else { return false }
        return characters[(index + count)...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func mergedOverlappingRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .sorted {
                if $0.location == $1.location { return $0.length > $1.length }
                return $0.location < $1.location
            }
        guard var current = sorted.first else { return [] }
        var merged: [NSRange] = []
        for range in sorted.dropFirst() {
            let currentEnd = current.location + current.length
            let rangeEnd = range.location + range.length
            if range.location < currentEnd {
                current.length = max(currentEnd, rangeEnd) - current.location
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
    }

    private static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            result.append(range)
            searchStart = range.upperBound
        }
        return result
    }

    private static func occurrenceCount(of needle: String, in text: String) -> Int {
        ranges(of: needle, in: text).count
    }

}
