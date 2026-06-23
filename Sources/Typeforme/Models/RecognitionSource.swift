import Foundation
import os.lock
@preconcurrency import Speech

extension RecognitionSource {
    var detail: String {
        switch self {
        case .qwen:
            return "Runs the local Qwen3-ASR model and contributes one transcript when its languages overlap the selected languages."
        case .nvidiaNemotron:
            return "Runs the local Nemotron 3.5 model and contributes one transcript when its languages overlap the selected languages."
        case .appleSpeech:
            return "Uses Apple's on-device recognizer on this Mac and contributes one transcript when the selected language is supported."
        }
    }

    func supportedLanguages() -> [ASRLanguageOption] {
        switch self {
        case .qwen:
            return ASRLanguageSelection.qwenASRSupportedLanguages
        case .nvidiaNemotron:
            return ASRLanguageSelection.nvidiaNemotronASRSupportedLanguages
        case .appleSpeech:
            return AppleSpeechLanguageSupport.supportedLanguages
        }
    }
}

extension Notification.Name {
    static let appleSpeechLanguageSupportDidChange = Notification.Name("TypeformeAppleSpeechLanguageSupportDidChange")
}

enum AppleSpeechLanguageSupport {
    private struct Cache: Sendable {
        var supportedLanguageIDs: Set<String>?
        var localeIDsByLanguageID: [String: String] = [:]
        var isRefreshing = false
    }

    private static let cache = OSAllocatedUnfairLock(initialState: Cache())

    static var supportedLanguages: [ASRLanguageOption] {
        if let supported = cache.withLock({ $0.supportedLanguageIDs }) {
            return ASRLanguageSelection.all.filter { supported.contains($0.id) }
        }
        refreshInBackgroundIfNeeded()
        return ASRLanguageSelection.all
    }

    static func effectiveLanguageIDs(_ languageIDs: [String]) -> [String] {
        ASRLanguageSelection.validatedIDs(languageIDs, supportedOptions: supportedLanguages)
    }

    static func bestSupportedLocaleIdentifier(for languageIDs: [String]) async -> (languageID: String, localeID: String)? {
        return await Task.detached(priority: .utility) {
            resolveBestSupportedLocaleIdentifier(for: languageIDs)
        }.value
    }

    private static func resolveBestSupportedLocaleIdentifier(for languageIDs: [String]) -> (languageID: String, localeID: String)? {
        for languageID in ASRLanguageSelection.validatedIDs(languageIDs) {
            guard let option = ASRLanguageSelection.option(for: languageID) else { continue }
            if let cached = cachedLocaleIdentifier(for: option.id) {
                return (languageID, cached)
            }
            if let localeID = resolveAndCacheBestLocaleIdentifier(for: option) {
                return (languageID, localeID)
            }
        }
        return nil
    }

    static func bestLocaleIdentifier(for languageID: String) -> String? {
        guard let option = ASRLanguageSelection.option(for: languageID) else { return nil }
        if let cached = cachedLocaleIdentifier(for: option.id) {
            return cached
        }
        guard !Thread.isMainThread else {
            refreshInBackgroundIfNeeded()
            return nil
        }
        return resolveAndCacheBestLocaleIdentifier(for: option)
    }

    private static func resolveAndCacheBestLocaleIdentifier(for option: ASRLanguageOption) -> String? {
        guard let localeID = resolveBestLocaleIdentifier(for: option) else { return nil }
        cache.withLock { state in
            state.localeIDsByLanguageID[option.id] = localeID
            var supported = state.supportedLanguageIDs ?? []
            supported.insert(option.id)
            state.supportedLanguageIDs = supported
        }
        return localeID
    }

    static func cachedBestLocaleIdentifier(for languageID: String) -> String? {
        guard let option = ASRLanguageSelection.option(for: languageID) else { return nil }
        return cachedLocaleIdentifier(for: option.id)
    }

    static func supports(_ languageID: String) -> Bool {
        bestLocaleIdentifier(for: languageID) != nil
    }

    static func refreshInBackgroundIfNeeded() {
        let shouldRefresh = cache.withLock { state -> Bool in
            guard state.supportedLanguageIDs == nil, !state.isRefreshing else { return false }
            state.isRefreshing = true
            return true
        }
        guard shouldRefresh else { return }

        Task.detached(priority: .utility) {
            var supportedLanguageIDs = Set<String>()
            var localeIDsByLanguageID: [String: String] = [:]
            for option in ASRLanguageSelection.all {
                guard let localeID = resolveBestLocaleIdentifier(for: option) else { continue }
                supportedLanguageIDs.insert(option.id)
                localeIDsByLanguageID[option.id] = localeID
            }

            let resolvedSupportedLanguageIDs = supportedLanguageIDs
            let resolvedLocaleIDsByLanguageID = localeIDsByLanguageID
            cache.withLock { state in
                state.supportedLanguageIDs = resolvedSupportedLanguageIDs
                state.localeIDsByLanguageID.merge(resolvedLocaleIDsByLanguageID) { _, new in new }
                state.isRefreshing = false
            }
            await MainActor.run {
                NotificationCenter.default.post(name: .appleSpeechLanguageSupportDidChange, object: nil)
            }
        }
    }

    private static func cachedLocaleIdentifier(for languageID: String) -> String? {
        cache.withLock { state in
            state.localeIDsByLanguageID[languageID]
        }
    }

    private static func resolveBestLocaleIdentifier(for option: ASRLanguageOption) -> String? {
        for localeID in candidateLocaleIdentifiers(for: option) {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
                  recognizer.supportsOnDeviceRecognition
            else { continue }
            return localeID
        }
        return nil
    }

    private static func candidateLocaleIdentifiers(for option: ASRLanguageOption) -> [String] {
        var candidates: [String] = []
        appendUnique(option.id, to: &candidates)
        appendUnique(option.id.replacingOccurrences(of: "-", with: "_"), to: &candidates)
        appendUnique(option.languageCode, to: &candidates)
        for identifier in preferredLocaleIdentifiersByLanguageID[option.id] ?? [] {
            appendUnique(identifier, to: &candidates)
        }
        for identifier in preferredLocaleIdentifiersByLanguageCode[option.languageCode] ?? [] {
            appendUnique(identifier, to: &candidates)
        }
        for identifier in Locale.availableIdentifiers {
            let locale = Locale(identifier: identifier)
            if normalizedLocaleIdentifier(identifier) == normalizedLocaleIdentifier(option.id) ||
                localeLanguageCode(locale) == option.languageCode {
                appendUnique(identifier, to: &candidates)
            }
        }
        return candidates
    }

    private static func localeLanguageCode(_ locale: Locale) -> String {
        if #available(macOS 13.0, *) {
            if let code = locale.language.languageCode?.identifier {
                return code
            }
        }
        return locale.identifier
    }

    private static func normalizedLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func appendUnique(_ identifier: String, to identifiers: inout [String]) {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = normalizedLocaleIdentifier(trimmed)
        guard !identifiers.contains(where: { normalizedLocaleIdentifier($0) == normalized }) else { return }
        identifiers.append(trimmed)
    }

    private static let preferredLocaleIdentifiersByLanguageID: [String: [String]] = [
        "zh-CN": ["zh-CN", "zh-Hans-CN", "zh-Hans"],
        "zh-TW": ["zh-TW", "zh-Hant-TW", "zh-HK", "zh-Hant"],
        "en-US": ["en-US", "en-GB", "en-AU", "en-CA", "en-IN"],
        "yue": ["yue-CN", "yue-HK", "zh-HK"],
    ]

    private static let preferredLocaleIdentifiersByLanguageCode: [String: [String]] = [
        "af": ["af-ZA"],
        "am": ["am-ET"],
        "ar": ["ar-SA", "ar-AE", "ar-EG"],
        "as": ["as-IN"],
        "az": ["az-AZ"],
        "ba": ["ba-RU"],
        "be": ["be-BY"],
        "bg": ["bg-BG"],
        "bn": ["bn-BD", "bn-IN"],
        "bo": ["bo-CN"],
        "br": ["br-FR"],
        "bs": ["bs-BA"],
        "ca": ["ca-ES"],
        "cs": ["cs-CZ"],
        "cy": ["cy-GB"],
        "da": ["da-DK"],
        "de": ["de-DE", "de-AT", "de-CH"],
        "el": ["el-GR"],
        "es": ["es-ES", "es-US", "es-MX"],
        "et": ["et-EE"],
        "eu": ["eu-ES"],
        "fa": ["fa-IR"],
        "fi": ["fi-FI"],
        "fo": ["fo-FO"],
        "fr": ["fr-FR", "fr-CA", "fr-CH"],
        "gl": ["gl-ES"],
        "gu": ["gu-IN"],
        "ha": ["ha-NG"],
        "haw": ["haw-US"],
        "he": ["he-IL"],
        "hi": ["hi-IN"],
        "hr": ["hr-HR"],
        "ht": ["ht-HT"],
        "hu": ["hu-HU"],
        "hy": ["hy-AM"],
        "id": ["id-ID"],
        "is": ["is-IS"],
        "it": ["it-IT"],
        "ja": ["ja-JP"],
        "jw": ["jv-ID"],
        "ka": ["ka-GE"],
        "kk": ["kk-KZ"],
        "km": ["km-KH"],
        "kn": ["kn-IN"],
        "ko": ["ko-KR"],
        "la": ["la-VA"],
        "lb": ["lb-LU"],
        "ln": ["ln-CD"],
        "lo": ["lo-LA"],
        "lt": ["lt-LT"],
        "lv": ["lv-LV"],
        "mg": ["mg-MG"],
        "mi": ["mi-NZ"],
        "mk": ["mk-MK"],
        "ml": ["ml-IN"],
        "mn": ["mn-MN"],
        "mr": ["mr-IN"],
        "ms": ["ms-MY"],
        "mt": ["mt-MT"],
        "my": ["my-MM"],
        "ne": ["ne-NP"],
        "nl": ["nl-NL", "nl-BE"],
        "nn": ["nn-NO"],
        "no": ["nb-NO", "no-NO"],
        "oc": ["oc-FR"],
        "pa": ["pa-IN"],
        "pl": ["pl-PL"],
        "ps": ["ps-AF"],
        "pt": ["pt-BR", "pt-PT"],
        "ro": ["ro-RO"],
        "ru": ["ru-RU"],
        "sa": ["sa-IN"],
        "sd": ["sd-IN"],
        "si": ["si-LK"],
        "sk": ["sk-SK"],
        "sl": ["sl-SI"],
        "sn": ["sn-ZW"],
        "so": ["so-SO"],
        "sq": ["sq-AL"],
        "sr": ["sr-RS"],
        "su": ["su-ID"],
        "sv": ["sv-SE"],
        "sw": ["sw-KE"],
        "ta": ["ta-IN", "ta-SG"],
        "te": ["te-IN"],
        "tg": ["tg-TJ"],
        "th": ["th-TH"],
        "tk": ["tk-TM"],
        "tl": ["fil-PH", "tl-PH"],
        "tr": ["tr-TR"],
        "tt": ["tt-RU"],
        "uk": ["uk-UA"],
        "ur": ["ur-PK", "ur-IN"],
        "uz": ["uz-UZ"],
        "vi": ["vi-VN"],
        "yi": ["yi-001"],
        "yo": ["yo-NG"],
    ]
}
