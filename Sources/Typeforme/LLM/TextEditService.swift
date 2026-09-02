import Foundation

@MainActor
final class TextEditService {
    private let dictionary: UserDictionaryStore
    private let aiWritingDecoder: any AIWritingDecoding

    init(dictionary: UserDictionaryStore, aiWritingDecoder: any AIWritingDecoding = AIWritingDecoderService.shared) {
        self.dictionary = dictionary
        self.aiWritingDecoder = aiWritingDecoder
    }

    func edit(
        intent: TextEditIntent,
        contextBefore: String,
        targetText: String,
        contextAfter: String,
        spokenInstruction: String,
        languageIDs: [String],
        appName: String?,
        bundleID: String?,
        appCategory: AppCategory
    ) async throws -> TextEditResult {
        let configuration = CorrectionSessionConfiguration.capture(
            userDictionary: dictionary.sortedSnapshot()
        )
        return try await edit(
            intent: intent,
            contextBefore: contextBefore,
            targetText: targetText,
            contextAfter: contextAfter,
            spokenInstruction: spokenInstruction,
            languageIDs: languageIDs,
            appName: appName,
            bundleID: bundleID,
            appCategory: appCategory,
            configuration: configuration
        )
    }

    func edit(
        intent: TextEditIntent,
        contextBefore: String,
        targetText: String,
        contextAfter: String,
        spokenInstruction: String,
        languageIDs: [String],
        appName: String?,
        bundleID: String?,
        appCategory: AppCategory,
        configuration: CorrectionSessionConfiguration
    ) async throws -> TextEditResult {
        let request = makeRequest(
            intent: intent,
            contextBefore: contextBefore,
            targetText: targetText,
            contextAfter: contextAfter,
            spokenInstruction: spokenInstruction,
            languageIDs: languageIDs,
            appName: appName,
            bundleID: bundleID,
            appCategory: appCategory,
            configuration: configuration
        )
        return try await edit(request, configuration: configuration)
    }

    func makeRequest(
        intent: TextEditIntent,
        contextBefore: String,
        targetText: String,
        contextAfter: String,
        spokenInstruction: String,
        languageIDs: [String],
        appName: String?,
        bundleID: String?,
        appCategory: AppCategory
    ) -> TextEditRequest {
        makeRequest(
            intent: intent,
            contextBefore: contextBefore,
            targetText: targetText,
            contextAfter: contextAfter,
            spokenInstruction: spokenInstruction,
            languageIDs: languageIDs,
            appName: appName,
            bundleID: bundleID,
            appCategory: appCategory,
            numberOutputPreference: AppSettings.numberOutputPreference,
            punctuationPreference: AppSettings.punctuationPreference,
            userDictionary: dictionary.sortedSnapshot()
        )
    }

    func makeRequest(
        intent: TextEditIntent,
        contextBefore: String,
        targetText: String,
        contextAfter: String,
        spokenInstruction: String,
        languageIDs: [String],
        appName: String?,
        bundleID: String?,
        appCategory: AppCategory,
        configuration: CorrectionSessionConfiguration
    ) -> TextEditRequest {
        makeRequest(
            intent: intent,
            contextBefore: contextBefore,
            targetText: targetText,
            contextAfter: contextAfter,
            spokenInstruction: spokenInstruction,
            languageIDs: languageIDs,
            appName: appName,
            bundleID: bundleID,
            appCategory: appCategory,
            numberOutputPreference: configuration.numberOutputPreference,
            punctuationPreference: configuration.punctuationPreference,
            userDictionary: configuration.userDictionary
        )
    }

    private func makeRequest(
        intent: TextEditIntent,
        contextBefore: String,
        targetText: String,
        contextAfter: String,
        spokenInstruction: String,
        languageIDs: [String],
        appName: String?,
        bundleID: String?,
        appCategory: AppCategory,
        numberOutputPreference: NumberOutputPreference,
        punctuationPreference: PunctuationOutputPreference,
        userDictionary: [DictionaryEntry]
    ) -> TextEditRequest {
        TextEditRequest(
            intent: intent,
            contextBefore: contextBefore,
            targetText: targetText,
            contextAfter: contextAfter,
            spokenInstruction: spokenInstruction,
            languageIDs: languageIDs,
            frontmostAppName: appName,
            frontmostBundleID: bundleID,
            appCategory: appCategory,
            numberOutputPreference: numberOutputPreference,
            punctuationPreference: punctuationPreference,
            userDictionary: userDictionary
        )
    }

    func edit(_ request: TextEditRequest) async throws -> TextEditResult {
        try await edit(
            request,
            configuration: .capture(userDictionary: dictionary.sortedSnapshot())
        )
    }

    func edit(
        _ request: TextEditRequest,
        configuration: CorrectionSessionConfiguration
    ) async throws -> TextEditResult {
        if request.intent == .pinyinToChinese,
           case .pinyinDecoder(let runtime) = configuration.aiWriting {
            guard let runtime else { throw AIWritingDecoderError.unavailable }
            let segments = try await aiWritingDecoder.decode(request, configuration: runtime)
            let formatted = try segments.map {
                try AIWritingOutputFormatter.format($0, numbers: request.numberOutputPreference, punctuation: request.punctuationPreference)
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "action": "replace_target", "converted_segments": formatted,
            ])
            return try TextEditValidator.parseAndValidate(rawOutput: String(decoding: data, as: UTF8.self), for: request)
        }
        let (system, user) = TextEditPromptBuilder.build(for: request)
        let output = try await configuration.corrector.complete(
            system: system,
            user: user,
            timeoutMs: configuration.timeoutMs
        )
        var result = try TextEditValidator.parseAndValidate(rawOutput: output, for: request)
        if request.intent == .pinyinToChinese {
            // Pinyin segments are normalized before the original separators
            // are reassembled. Whole-text cleanup would erase those boundaries.
            return result
        }
        result.text = LocaleTextNormalizer.normalize(result.text, languageIDs: request.languageIDs)
        result.text = TranscriptPostProcessor.clean(
            result.text,
            languageIDs: request.languageIDs,
            preserveLineBreaks: true,
            punctuationPreference: request.punctuationPreference
        )
        return result
    }
}
