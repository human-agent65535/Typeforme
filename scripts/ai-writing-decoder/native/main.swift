import Foundation

while let line = readLine() {
    do {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        let source = object["input"] as! String
        let numbers = NumberOutputPreference.normalized(object["numbers"] as? String)
        let punctuation = PunctuationOutputPreference.normalized(object["punctuation"] as? String)
        let mask = VerbatimSpanMask(source, inputKind: .mixedTyping)
        var result: [String: Any] = [
            "input_segments": PinyinDraftLayout(source).segments,
            "protected_literals": mask.entries.map(\.text),
            "format_reminder": OutputPreferencePrompt.finalReminder(numbers: numbers, punctuation: .normal),
        ]
        var protectedRanges: [NSRange] = []
        var searchStart = source.startIndex
        for entry in mask.entries {
            if let range = source.range(of: entry.text, range: searchStart..<source.endIndex) {
                protectedRanges.append(NSRange(range, in: source))
                searchStart = range.upperBound
            }
        }
        let matcher = try NSRegularExpression(pattern: "[A-Za-z]+(?:'[A-Za-z]+)*")
        let ns = source as NSString
        result["latin_spans"] = matcher.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap { match -> [String: Any]? in
            guard !protectedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return nil }
            return ["start": match.range.location, "end": match.range.location + match.range.length, "raw": ns.substring(with: match.range)]
        }
        if let raw = object["output"] as? String {
            let request = TextEditRequest(intent: .pinyinToChinese, contextBefore: "", targetText: source,
                contextAfter: "", spokenInstruction: "", languageIDs: ["zh-CN", "en-US"],
                frontmostAppName: nil, frontmostBundleID: nil, appCategory: .chat,
                numberOutputPreference: numbers, punctuationPreference: punctuation, userDictionary: [])
            do {
                result["text"] = try TextEditValidator.parseAndValidate(rawOutput: raw, for: request).text
                result["valid"] = true
            } catch {
                result["valid"] = false
                result["validation_error"] = error.localizedDescription
            }
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .fragmentsAllowed])
        print(String(data: data, encoding: .utf8)!)
    } catch {
        print("{\"error\":\"invalid diagnostic input\"}")
    }
    fflush(stdout)
}
