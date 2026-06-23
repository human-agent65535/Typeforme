import Foundation
import os.lock

enum EnglishPronunciationLexicon {
    private static let dictionaryLock = OSAllocatedUnfairLock<[String: [[String]]]?>(
        initialState: nil
    )

    static func pinyinSyllableLists(for word: String) -> [[String]] {
        let key = normalizedKey(word)
        guard key.count >= 2 else { return [] }
        return Array((dictionary()[key] ?? []).prefix(4))
    }

    private static func dictionary() -> [String: [[String]]] {
        dictionaryLock.withLock { cached in
            if let cached {
                return cached
            }
            let loaded = loadDictionary()
            cached = loaded
            return loaded
        }
    }

    private static func loadDictionary() -> [String: [[String]]] {
        guard let url = Bundle.module.url(forResource: "cmudict", withExtension: "dict"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }

        var output: [String: [[String]]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix(";;;") else { continue }
            let parts = line.split { $0 == " " || $0 == "\t" }.map(String.init)
            guard parts.count > 1 else { continue }
            let key = normalizedDictionaryHeadword(parts[0])
            guard key.count >= 2 else { continue }
            let phonemes = parts.dropFirst().map(stripStress)
            for syllables in pinyinSyllables(forARPABET: Array(phonemes)) {
                appendUnique(syllables, for: key, to: &output)
            }
        }
        return output
    }

    private static func pinyinSyllables(forARPABET phonemes: [String]) -> [[String]] {
        var syllables: [String] = []
        var index = 0
        while index < phonemes.count {
            if isVowel(phonemes[index]) {
                syllables.append(vowelPinyin(phonemes[index]))
                index += 1
                continue
            }

            var cluster: [String] = []
            while index < phonemes.count, !isVowel(phonemes[index]) {
                cluster.append(phonemes[index])
                index += 1
            }

            guard index < phonemes.count else {
                for consonant in cluster {
                    syllables.append(standaloneConsonantPinyin(consonant))
                }
                continue
            }

            let vowel = phonemes[index]
            for consonant in cluster.dropLast() {
                syllables.append(standaloneConsonantPinyin(consonant))
            }
            if let onset = cluster.last {
                syllables.append(composedSyllable(onset: onset, vowel: vowel))
            } else {
                syllables.append(vowelPinyin(vowel))
            }
            index += 1
        }

        let cleaned = syllables.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return [] }
        var variants = [cleaned]
        variants.append(contentsOf: contractedFinalVariants(cleaned))
        return unique(variants)
    }

    private static func contractedFinalVariants(_ syllables: [String]) -> [[String]] {
        guard syllables.count >= 2 else { return [] }
        let suffix = Array(syllables.suffix(2))
        let prefix = Array(syllables.dropLast(2))
        switch suffix {
        case ["ke", "er"]:
            return [prefix + ["kou"]]
        case ["ge", "er"]:
            return [prefix + ["gou"]]
        default:
            return []
        }
    }

    private static func composedSyllable(onset: String, vowel: String) -> String {
        let vowel = vowelPinyin(vowel)
        guard !vowel.isEmpty else { return standaloneConsonantPinyin(onset) }
        switch onset {
        case "CH":
            return vowel == "i" ? "chi" : "q" + vowel
        case "JH":
            return vowel == "i" ? "ji" : "j" + vowel
        case "SH":
            return vowel == "i" ? "shi" : "sh" + vowel
        case "TH":
            return "s" + vowel
        case "DH":
            return "d" + vowel
        case "V":
            return "w" + vowel
        case "W":
            return "w" + vowel
        case "Y":
            return vowel == "i" ? "yi" : "y" + vowel
        case "HH":
            return "h" + vowel
        default:
            return (initialPinyin(onset) ?? "") + vowel
        }
    }

    private static func initialPinyin(_ phoneme: String) -> String? {
        switch phoneme {
        case "B": return "b"
        case "P": return "p"
        case "M": return "m"
        case "F": return "f"
        case "D": return "d"
        case "T": return "t"
        case "N": return "n"
        case "L": return "l"
        case "G": return "g"
        case "K": return "k"
        case "R": return "r"
        case "S": return "s"
        case "Z": return "z"
        default: return nil
        }
    }

    private static func standaloneConsonantPinyin(_ phoneme: String) -> String {
        switch phoneme {
        case "B": return "bu"
        case "CH": return "qi"
        case "D": return "de"
        case "DH": return "de"
        case "F": return "fu"
        case "G": return "ge"
        case "HH": return "he"
        case "JH": return "ji"
        case "K": return "ke"
        case "L": return "er"
        case "M": return "mu"
        case "N", "NG": return "en"
        case "P": return "pu"
        case "R": return "er"
        case "S": return "si"
        case "SH": return "shi"
        case "T": return "te"
        case "TH": return "si"
        case "V": return "wei"
        case "W": return "wu"
        case "Y": return "yi"
        case "Z": return "zi"
        case "ZH": return "zhi"
        default: return phoneme.lowercased()
        }
    }

    private static func vowelPinyin(_ phoneme: String) -> String {
        switch phoneme {
        case "AA", "AH": return "e"
        case "AE", "EH": return "ai"
        case "AO": return "ao"
        case "AW": return "ao"
        case "AY": return "ai"
        case "ER": return "er"
        case "EY": return "ei"
        case "IH", "IY": return "i"
        case "OW", "OY": return "ou"
        case "UH", "UW": return "u"
        default: return phoneme.lowercased()
        }
    }

    private static func isVowel(_ phoneme: String) -> Bool {
        switch phoneme {
        case "AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY",
             "IH", "IY", "OW", "OY", "UH", "UW":
            return true
        default:
            return false
        }
    }

    private static func normalizedDictionaryHeadword(_ value: String) -> String {
        let withoutVariant = value.replacingOccurrences(
            of: #"\(\d+\)$"#,
            with: "",
            options: .regularExpression
        )
        return normalizedKey(withoutVariant)
    }

    private static func normalizedKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "'" }
            .map(String.init)
            .joined()
    }

    private static func stripStress(_ value: String) -> String {
        value.filter { !$0.isNumber }
    }

    private static func appendUnique(
        _ syllables: [String],
        for key: String,
        to dictionary: inout [String: [[String]]]
    ) {
        guard !syllables.isEmpty else { return }
        var values = dictionary[key] ?? []
        guard !values.contains(syllables) else { return }
        values.append(syllables)
        dictionary[key] = Array(values.prefix(6))
    }

    private static func unique(_ values: [[String]]) -> [[String]] {
        var seen = Set<String>()
        var output: [[String]] = []
        for value in values {
            let key = value.joined(separator: " ")
            guard seen.insert(key).inserted else { continue }
            output.append(value)
        }
        return output
    }
}
