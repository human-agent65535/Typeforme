import Foundation

/// Normalizes raw model output before JSON validation:
///   raw model output → strip <think> blocks → strip code fences →
///   extract first JSON object
enum ModelOutputCleaner {
    static func clean(_ raw: String) -> String {
        let noThink = stripThinkBlocks(raw)
        let noFences = stripFences(noThink)
        return noFences.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripLeadingEmptyThinkBlock(_ raw: String) -> String {
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        return leadingEmptyThinkBlockRegex
            .stringByReplacingMatches(in: raw, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unwraps a single outer Markdown code fence only when the whole model
    /// output is that fence. This is intentionally narrower than `clean(_:)`
    /// so final-output validation does not accept prose plus fenced JSON.
    static func unwrapSingleCodeFence(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"),
              let openingEnd = trimmed.firstIndex(of: "\n")
        else { return nil }

        let opening = trimmed[..<openingEnd]
        let tag = opening.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
        guard tag.allSatisfy({ character in
            character.isLetter || character.isNumber || character == "_" || character == "+" || character == "-"
        }) else { return nil }

        let bodyStart = trimmed.index(after: openingEnd)
        let bodyAndClosing = trimmed[bodyStart...]
        guard bodyAndClosing.hasSuffix("```") else { return nil }

        let closingStart = bodyAndClosing.index(bodyAndClosing.endIndex, offsetBy: -3)
        let body = bodyAndClosing[..<closingStart]
        guard body.last == "\n" || body.last == "\r" else { return nil }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the first balanced `{ ... }` substring, respecting quoted strings
    /// and backslash escapes. Returns nil if no balanced object exists.
    static func extractFirstJSONObject(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if escape { escape = false; i = s.index(after: i); continue }
            if inString {
                switch c {
                case "\\": escape = true
                case "\"": inString = false
                default: break
                }
                i = s.index(after: i); continue
            }
            switch c {
            case "\"": inString = true
            case "{":  depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    let end = s.index(after: i)
                    return String(s[start..<end])
                }
            default: break
            }
            i = s.index(after: i)
        }
        return nil
    }

    private static func stripThinkBlocks(_ s: String) -> String {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return thinkBlockRegex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    private static func stripFences(_ s: String) -> String {
        // Strip ``` optionally followed by a language tag and a newline, plus closing ```.
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return codeFenceRegex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    private static let thinkBlockRegex = try! NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>")
    private static let leadingEmptyThinkBlockRegex = try! NSRegularExpression(pattern: #"^\s*<think>\s*</think>\s*"#)
    private static let codeFenceRegex = try! NSRegularExpression(pattern: "```[a-zA-Z0-9_+\\-]*\\n?|```")
}
