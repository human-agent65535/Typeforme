import Foundation

/// Candidate scoring chooses content; formatting cannot introduce another
/// model rewrite. Numeric/code literals and the user's separators stay owned
/// by the existing pinyin layout contract.
enum AIWritingOutputFormatter {
    static func format(_ segment: String, numbers: NumberOutputPreference, punctuation: PunctuationOutputPreference) throws -> String {
        let mask = VerbatimSpanMask(segment, inputKind: .mixedTyping)
        var text = mask.maskedText
        // Only unambiguous counted quantities are reformatted. Identifiers,
        // dates, decimal literals and idioms such as 一起 remain verbatim.
        let classifiers = "(?:个|件|本|张|台|条|杯|份|次|位|名|只|支|包|箱|辆|套|块|页|颗|枚|双|瓶|元|岁|天|小时|分钟|秒|米|公斤)"
        if numbers == .words {
            text = replacingMatches(#"(?<![A-Za-z0-9_])(?:0|[1-9][0-9]{0,8})(?="# + classifiers + ")", in: text) { value in
                let formatter = NumberFormatter()
                formatter.locale = Locale(identifier: "zh_Hans_CN")
                formatter.numberStyle = .spellOut
                guard let number = Int(value) else { return value }
                return formatter.string(from: NSNumber(value: number)) ?? value
            }
        } else if numbers == .digits {
            text = replacingMatches("[零〇一二两三四五六七八九十百千万亿]+(?=" + classifiers + ")", in: text) { value in
                let formatter = NumberFormatter()
                formatter.locale = Locale(identifier: "zh_Hans_CN")
                formatter.numberStyle = .spellOut
                return formatter.number(from: value.replacingOccurrences(of: "两", with: "二"))?.stringValue ?? value
            }
        }
        if punctuation == .normal, text.range(of: #"\p{Han}"#, options: .regularExpression) != nil {
            let mapping: [Character: Character] = [",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；"]
            text = String(text.map { mapping[$0] ?? $0 })
        }
        guard let restored = mask.restoring(text) else { throw AIWritingDecoderError.invalidResponse }
        return restored
    }

    private static func replacingMatches(_ pattern: String, in text: String, transform: (String) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }
}
