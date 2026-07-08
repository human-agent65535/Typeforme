import Foundation

enum ChineseScriptPreference: Sendable, Hashable {
    case simplified
    case traditional
    case preserve
}

struct ASRLanguageOption: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let languageCode: String
    let chineseScript: ChineseScriptPreference
    let commonRank: Int?

    init(
        id: String,
        displayName: String,
        languageCode: String,
        chineseScript: ChineseScriptPreference = .preserve,
        commonRank: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.languageCode = languageCode
        self.chineseScript = chineseScript
        self.commonRank = commonRank
    }

    var isCommon: Bool { commonRank != nil }
}

enum ASRLanguageSelection {
    static let defaultIDs = ["zh-CN", "en-US"]
    static let defaultRawValue = rawValue(for: defaultIDs)

    static let all: [ASRLanguageOption] = [
        ASRLanguageOption(id: "zh-CN", displayName: "Chinese (Simplified)", languageCode: "zh", chineseScript: .simplified, commonRank: 0),
        ASRLanguageOption(id: "zh-TW", displayName: "Chinese (Traditional)", languageCode: "zh", chineseScript: .traditional, commonRank: 1),
        ASRLanguageOption(id: "en-US", displayName: "English", languageCode: "en", commonRank: 2),
        ASRLanguageOption(id: "ja", displayName: "Japanese", languageCode: "ja", commonRank: 3),
        ASRLanguageOption(id: "ko", displayName: "Korean", languageCode: "ko", commonRank: 4),
        ASRLanguageOption(id: "fr", displayName: "French", languageCode: "fr", commonRank: 5),
        ASRLanguageOption(id: "de", displayName: "German", languageCode: "de", commonRank: 6),
        ASRLanguageOption(id: "es", displayName: "Spanish", languageCode: "es", commonRank: 7),
        ASRLanguageOption(id: "af", displayName: "Afrikaans", languageCode: "af"),
        ASRLanguageOption(id: "sq", displayName: "Albanian", languageCode: "sq"),
        ASRLanguageOption(id: "am", displayName: "Amharic", languageCode: "am"),
        ASRLanguageOption(id: "ar", displayName: "Arabic", languageCode: "ar"),
        ASRLanguageOption(id: "hy", displayName: "Armenian", languageCode: "hy"),
        ASRLanguageOption(id: "as", displayName: "Assamese", languageCode: "as"),
        ASRLanguageOption(id: "az", displayName: "Azerbaijani", languageCode: "az"),
        ASRLanguageOption(id: "ba", displayName: "Bashkir", languageCode: "ba"),
        ASRLanguageOption(id: "eu", displayName: "Basque", languageCode: "eu"),
        ASRLanguageOption(id: "be", displayName: "Belarusian", languageCode: "be"),
        ASRLanguageOption(id: "bn", displayName: "Bengali", languageCode: "bn"),
        ASRLanguageOption(id: "bs", displayName: "Bosnian", languageCode: "bs"),
        ASRLanguageOption(id: "br", displayName: "Breton", languageCode: "br"),
        ASRLanguageOption(id: "bg", displayName: "Bulgarian", languageCode: "bg"),
        ASRLanguageOption(id: "my", displayName: "Burmese / Myanmar", languageCode: "my"),
        ASRLanguageOption(id: "ca", displayName: "Catalan", languageCode: "ca"),
        ASRLanguageOption(id: "yue", displayName: "Cantonese", languageCode: "yue"),
        ASRLanguageOption(id: "hr", displayName: "Croatian", languageCode: "hr"),
        ASRLanguageOption(id: "cs", displayName: "Czech", languageCode: "cs"),
        ASRLanguageOption(id: "da", displayName: "Danish", languageCode: "da"),
        ASRLanguageOption(id: "nl", displayName: "Dutch", languageCode: "nl"),
        ASRLanguageOption(id: "et", displayName: "Estonian", languageCode: "et"),
        ASRLanguageOption(id: "fo", displayName: "Faroese", languageCode: "fo"),
        ASRLanguageOption(id: "fi", displayName: "Finnish", languageCode: "fi"),
        ASRLanguageOption(id: "gl", displayName: "Galician", languageCode: "gl"),
        ASRLanguageOption(id: "ka", displayName: "Georgian", languageCode: "ka"),
        ASRLanguageOption(id: "el", displayName: "Greek", languageCode: "el"),
        ASRLanguageOption(id: "gu", displayName: "Gujarati", languageCode: "gu"),
        ASRLanguageOption(id: "ht", displayName: "Haitian Creole", languageCode: "ht"),
        ASRLanguageOption(id: "ha", displayName: "Hausa", languageCode: "ha"),
        ASRLanguageOption(id: "haw", displayName: "Hawaiian", languageCode: "haw"),
        ASRLanguageOption(id: "he", displayName: "Hebrew", languageCode: "he"),
        ASRLanguageOption(id: "hi", displayName: "Hindi", languageCode: "hi"),
        ASRLanguageOption(id: "hu", displayName: "Hungarian", languageCode: "hu"),
        ASRLanguageOption(id: "is", displayName: "Icelandic", languageCode: "is"),
        ASRLanguageOption(id: "id", displayName: "Indonesian", languageCode: "id"),
        ASRLanguageOption(id: "it", displayName: "Italian", languageCode: "it"),
        ASRLanguageOption(id: "jw", displayName: "Javanese", languageCode: "jw"),
        ASRLanguageOption(id: "kn", displayName: "Kannada", languageCode: "kn"),
        ASRLanguageOption(id: "kk", displayName: "Kazakh", languageCode: "kk"),
        ASRLanguageOption(id: "km", displayName: "Khmer", languageCode: "km"),
        ASRLanguageOption(id: "lo", displayName: "Lao", languageCode: "lo"),
        ASRLanguageOption(id: "la", displayName: "Latin", languageCode: "la"),
        ASRLanguageOption(id: "lv", displayName: "Latvian", languageCode: "lv"),
        ASRLanguageOption(id: "ln", displayName: "Lingala", languageCode: "ln"),
        ASRLanguageOption(id: "lt", displayName: "Lithuanian", languageCode: "lt"),
        ASRLanguageOption(id: "lb", displayName: "Luxembourgish", languageCode: "lb"),
        ASRLanguageOption(id: "mk", displayName: "Macedonian", languageCode: "mk"),
        ASRLanguageOption(id: "mg", displayName: "Malagasy", languageCode: "mg"),
        ASRLanguageOption(id: "ms", displayName: "Malay", languageCode: "ms"),
        ASRLanguageOption(id: "ml", displayName: "Malayalam", languageCode: "ml"),
        ASRLanguageOption(id: "mt", displayName: "Maltese", languageCode: "mt"),
        ASRLanguageOption(id: "mi", displayName: "Maori", languageCode: "mi"),
        ASRLanguageOption(id: "mr", displayName: "Marathi", languageCode: "mr"),
        ASRLanguageOption(id: "mn", displayName: "Mongolian", languageCode: "mn"),
        ASRLanguageOption(id: "ne", displayName: "Nepali", languageCode: "ne"),
        ASRLanguageOption(id: "no", displayName: "Norwegian", languageCode: "no"),
        ASRLanguageOption(id: "nn", displayName: "Norwegian Nynorsk", languageCode: "nn"),
        ASRLanguageOption(id: "oc", displayName: "Occitan", languageCode: "oc"),
        ASRLanguageOption(id: "ps", displayName: "Pashto", languageCode: "ps"),
        ASRLanguageOption(id: "fa", displayName: "Persian", languageCode: "fa"),
        ASRLanguageOption(id: "pl", displayName: "Polish", languageCode: "pl"),
        ASRLanguageOption(id: "pt", displayName: "Portuguese", languageCode: "pt"),
        ASRLanguageOption(id: "pa", displayName: "Punjabi", languageCode: "pa"),
        ASRLanguageOption(id: "ro", displayName: "Romanian", languageCode: "ro"),
        ASRLanguageOption(id: "ru", displayName: "Russian", languageCode: "ru"),
        ASRLanguageOption(id: "sa", displayName: "Sanskrit", languageCode: "sa"),
        ASRLanguageOption(id: "sr", displayName: "Serbian", languageCode: "sr"),
        ASRLanguageOption(id: "sn", displayName: "Shona", languageCode: "sn"),
        ASRLanguageOption(id: "sd", displayName: "Sindhi", languageCode: "sd"),
        ASRLanguageOption(id: "si", displayName: "Sinhala", languageCode: "si"),
        ASRLanguageOption(id: "sk", displayName: "Slovak", languageCode: "sk"),
        ASRLanguageOption(id: "sl", displayName: "Slovenian", languageCode: "sl"),
        ASRLanguageOption(id: "so", displayName: "Somali", languageCode: "so"),
        ASRLanguageOption(id: "su", displayName: "Sundanese", languageCode: "su"),
        ASRLanguageOption(id: "sw", displayName: "Swahili", languageCode: "sw"),
        ASRLanguageOption(id: "sv", displayName: "Swedish", languageCode: "sv"),
        ASRLanguageOption(id: "tl", displayName: "Filipino / Tagalog", languageCode: "tl"),
        ASRLanguageOption(id: "tg", displayName: "Tajik", languageCode: "tg"),
        ASRLanguageOption(id: "ta", displayName: "Tamil", languageCode: "ta"),
        ASRLanguageOption(id: "tt", displayName: "Tatar", languageCode: "tt"),
        ASRLanguageOption(id: "te", displayName: "Telugu", languageCode: "te"),
        ASRLanguageOption(id: "th", displayName: "Thai", languageCode: "th"),
        ASRLanguageOption(id: "bo", displayName: "Tibetan", languageCode: "bo"),
        ASRLanguageOption(id: "tr", displayName: "Turkish", languageCode: "tr"),
        ASRLanguageOption(id: "tk", displayName: "Turkmen", languageCode: "tk"),
        ASRLanguageOption(id: "uk", displayName: "Ukrainian", languageCode: "uk"),
        ASRLanguageOption(id: "ur", displayName: "Urdu", languageCode: "ur"),
        ASRLanguageOption(id: "uz", displayName: "Uzbek", languageCode: "uz"),
        ASRLanguageOption(id: "vi", displayName: "Vietnamese", languageCode: "vi"),
        ASRLanguageOption(id: "cy", displayName: "Welsh", languageCode: "cy"),
        ASRLanguageOption(id: "yi", displayName: "Yiddish", languageCode: "yi"),
        ASRLanguageOption(id: "yo", displayName: "Yoruba", languageCode: "yo"),
    ]

    static var common: [ASRLanguageOption] {
        all.filter(\.isCommon).sorted { ($0.commonRank ?? .max) < ($1.commonRank ?? .max) }
    }

    static let qwenASRSupportedLanguageIDs = [
        "zh-CN", "zh-TW", "en-US", "yue", "ar", "de", "fr", "es",
        "pt", "id", "it", "ko", "ru", "th", "vi", "ja",
        "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl",
        "cs", "tl", "fa", "el", "hu", "mk", "ro",
    ]

    static var qwenASRSupportedLanguages: [ASRLanguageOption] {
        let supported = Set(qwenASRSupportedLanguageIDs)
        return all.filter { supported.contains($0.id) }
    }

    static let nvidiaNemotronASRSupportedLanguageIDs = [
        "en-US", "es", "fr", "it", "pt", "nl", "de", "tr",
        "ru", "ar", "hi", "ja", "ko", "vi", "uk", "pl",
        "sv", "cs", "no", "da", "bg", "fi", "hr", "sk",
        "zh-CN", "hu", "ro", "et",
    ]

    static var nvidiaNemotronASRSupportedLanguages: [ASRLanguageOption] {
        let supported = Set(nvidiaNemotronASRSupportedLanguageIDs)
        return all.filter { supported.contains($0.id) }
    }

    static func supportedOptions(for sources: [RecognitionSource]) -> [ASRLanguageOption] {
        guard !sources.isEmpty else { return [] }
        let supportedIDs = Set(sources.flatMap { $0.supportedLanguages().map(\.id) })
        let result = all.filter { supportedIDs.contains($0.id) }
        return result
    }

    static func supportedOptions(for source: RecognitionSource) -> [ASRLanguageOption] {
        source.supportedLanguages()
    }

    static func commonOptions(for sources: [RecognitionSource]) -> [ASRLanguageOption] {
        supportedOptions(for: sources)
            .filter(\.isCommon)
            .sorted { ($0.commonRank ?? .max) < ($1.commonRank ?? .max) }
    }

    static func parse(_ rawValue: String) -> [String] {
        parse(rawValue, supportedOptions: all)
    }

    static func parse(_ rawValue: String, sources: [RecognitionSource]) -> [String] {
        parse(rawValue, supportedOptions: supportedOptions(for: sources))
    }

    static func parse(_ rawValue: String, supportedOptions: [ASRLanguageOption]) -> [String] {
        let ids = rawValue
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\t" || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return validatedIDs(ids, supportedOptions: supportedOptions)
    }

    static func rawValue(for ids: [String]) -> String {
        validatedIDs(ids).joined(separator: ",")
    }

    static func rawValue(for ids: [String], supportedOptions: [ASRLanguageOption]) -> String {
        validatedIDs(ids, supportedOptions: supportedOptions).joined(separator: ",")
    }

    static func validatedIDs(_ ids: [String]) -> [String] {
        validatedIDs(ids, supportedOptions: all)
    }

    static func validatedIDs(_ ids: [String], sources: [RecognitionSource]) -> [String] {
        validatedIDs(ids, supportedOptions: supportedOptions(for: sources))
    }

    static func validatedIDs(_ ids: [String], supportedOptions: [ASRLanguageOption]) -> [String] {
        guard !supportedOptions.isEmpty else { return [] }
        let options = supportedOptions
        let canonical = Set(ids.compactMap(canonicalID(for:)))
        guard !canonical.isEmpty else { return defaultIDs(for: options) }
        let selected = options.map(\.id).filter { canonical.contains($0) }
        return selected.isEmpty ? defaultIDs(for: options) : selected
    }

    static func filteredIDs(_ ids: [String], supportedOptions: [ASRLanguageOption]) -> [String] {
        guard !supportedOptions.isEmpty else { return [] }
        let canonical = Set(ids.compactMap(canonicalID(for:)))
        guard !canonical.isEmpty else { return [] }
        return supportedOptions.map(\.id).filter { canonical.contains($0) }
    }

    static func option(for id: String) -> ASRLanguageOption? {
        guard let canonical = canonicalID(for: id) else { return nil }
        return optionsByID[canonical]
    }

    static func displayNames(for ids: [String]) -> [String] {
        displayNames(for: ids, supportedOptions: all)
    }

    static func displayNames(for ids: [String], supportedOptions: [ASRLanguageOption]) -> [String] {
        let optionsByID = Dictionary(uniqueKeysWithValues: supportedOptions.map { ($0.id, $0) })
        return validatedIDs(ids, supportedOptions: supportedOptions).compactMap { optionsByID[$0]?.displayName }
    }

    static func effectiveIDs(_ ids: [String], for source: RecognitionSource) -> [String] {
        filteredIDs(ids, supportedOptions: source.supportedLanguages())
    }

    static func languageCodes(for ids: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in validatedIDs(ids) {
            guard let code = optionsByID[id]?.languageCode, !seen.contains(code) else { continue }
            seen.insert(code)
            result.append(code)
        }
        return result
    }

    static func languageHint(for ids: [String]) -> String? {
        let codes = languageCodes(for: ids)
        return codes.count == 1 ? codes[0] : nil
    }

    static func scriptPreference(for ids: [String]) -> ChineseScriptPreference {
        let scripts = Set(validatedIDs(ids).compactMap { id -> ChineseScriptPreference? in
            guard let script = optionsByID[id]?.chineseScript, script != .preserve else { return nil }
            return script
        })
        if scripts == [.simplified] { return .simplified }
        if scripts == [.traditional] { return .traditional }
        return .preserve
    }

    static func primaryLanguageID(for ids: [String]) -> String {
        validatedIDs(ids).first ?? defaultIDs[0]
    }

    private static let optionsByID: [String: ASRLanguageOption] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    private static func defaultIDs(for supportedOptions: [ASRLanguageOption]) -> [String] {
        guard !supportedOptions.isEmpty else { return [] }
        let supported = Set(supportedOptions.map(\.id))
        let defaults = defaultIDs.filter { supported.contains($0) }
        if !defaults.isEmpty { return defaults }
        return supportedOptions.first.map { [$0.id] } ?? defaultIDs
    }

    private static func canonicalID(for rawID: String) -> String? {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        switch lower {
        case "auto":
            return nil
        case "zh", "zh-cn", "zh-hans", "zh-sg":
            return "zh-CN"
        case "zh-tw", "zh-hant", "zh-hk", "zh-mo":
            return "zh-TW"
        case "en", "en-us", "en-gb":
            return "en-US"
        case "ar-ar":
            return "ar"
        case "bg-bg":
            return "bg"
        case "cs-cz":
            return "cs"
        case "da-dk":
            return "da"
        case "de-de":
            return "de"
        case "el-gr":
            return "el"
        case "es-es", "es-us":
            return "es"
        case "et-ee":
            return "et"
        case "fi-fi":
            return "fi"
        case "fr-fr", "fr-ca":
            return "fr"
        case "he-il":
            return "he"
        case "hi-in":
            return "hi"
        case "hr-hr":
            return "hr"
        case "hu-hu":
            return "hu"
        case "it-it":
            return "it"
        case "ja-jp":
            return "ja"
        case "ko-kr":
            return "ko"
        case "lt-lt":
            return "lt"
        case "lv-lv":
            return "lv"
        case "mt-mt":
            return "mt"
        case "nb-no":
            return "no"
        case "nl-nl":
            return "nl"
        case "pl-pl":
            return "pl"
        case "pt-br", "pt-pt":
            return "pt"
        case "ro-ro":
            return "ro"
        case "ru-ru":
            return "ru"
        case "sk-sk":
            return "sk"
        case "sl-si":
            return "sl"
        case "sv-se":
            return "sv"
        case "th-th":
            return "th"
        case "tr-tr":
            return "tr"
        case "uk-ua":
            return "uk"
        case "vi-vn":
            return "vi"
        case "fil":
            return "tl"
        default:
            return all.first {
                $0.id.lowercased() == lower ||
                    $0.languageCode == lower
            }?.id
        }
    }
}
