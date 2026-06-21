import Foundation
@preconcurrency import Speech

enum RecognitionSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case qwen = "qwen3-asr-llama"
    case nvidiaNemotron = "nvidia-nemotron-asr"
    case appleSpeech = "apple-speech"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen:
            return "Qwen3-ASR"
        case .nvidiaNemotron:
            return "NVIDIA Nemotron 3.5 ASR"
        case .appleSpeech:
            return "Apple Speech"
        }
    }

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

    var hasModelConfiguration: Bool {
        switch self {
        case .qwen, .nvidiaNemotron:
            return true
        case .appleSpeech:
            return false
        }
    }

    var supportsLivePreview: Bool {
        switch self {
        case .nvidiaNemotron, .appleSpeech:
            return true
        case .qwen:
            return false
        }
    }

    static let defaultEnabled: [RecognitionSource] = [.qwen]

    static func normalizedSources(_ raw: [String]) -> [RecognitionSource] {
        var seen = Set<RecognitionSource>()
        let values = raw.compactMap { value -> RecognitionSource? in
            RecognitionSource(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        let result = values.filter { seen.insert($0).inserted }
        return result.isEmpty ? defaultEnabled : result
    }

    static func rawValue(for sources: [RecognitionSource]) -> String {
        sources.map(\.rawValue).joined(separator: ",")
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

enum AppleSpeechLanguageSupport {
    static var supportedLanguages: [ASRLanguageOption] {
        ASRLanguageSelection.all.filter { bestLocaleIdentifier(for: $0.id) != nil }
    }

    static func effectiveLanguageIDs(_ languageIDs: [String]) -> [String] {
        ASRLanguageSelection.validatedIDs(languageIDs, supportedOptions: supportedLanguages)
    }

    static func bestLocaleIdentifier(for languageID: String) -> String? {
        guard let option = ASRLanguageSelection.option(for: languageID) else { return nil }
        let candidates = supportedOnDeviceLocales()
        let normalizedID = normalizedLocaleIdentifier(option.id)
        if let exact = candidates.first(where: { normalizedLocaleIdentifier($0.identifier) == normalizedID }) {
            return exact.identifier
        }
        if let languageMatch = candidates.first(where: { localeLanguageCode($0) == option.languageCode }) {
            return languageMatch.identifier
        }
        return nil
    }

    static func supports(_ languageID: String) -> Bool {
        bestLocaleIdentifier(for: languageID) != nil
    }

    private static func supportedOnDeviceLocales() -> [Locale] {
        SFSpeechRecognizer.supportedLocales()
            .filter { locale in
                guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
                return recognizer.supportsOnDeviceRecognition
            }
            .sorted { $0.identifier < $1.identifier }
    }

    private static func localeLanguageCode(_ locale: Locale) -> String {
        if #available(macOS 13.0, *) {
            if let code = locale.language.languageCode?.identifier {
                return code
            }
        }
        return Locale(identifier: locale.identifier).languageCode ?? locale.identifier
    }

    private static func normalizedLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
