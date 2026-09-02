import Foundation

@MainActor
final class TextEditService {
    private let dictionary: UserDictionaryStore

    init(dictionary: UserDictionaryStore) {
        self.dictionary = dictionary
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
        let (system, user) = TextEditPromptBuilder.build(for: request)
        let output = try await configuration.corrector.complete(
            system: system,
            user: user,
            timeoutMs: configuration.timeoutMs
        )
        var result = try TextEditValidator.parseAndValidate(rawOutput: output, for: request)
        if request.intent == .pinyinToChinese {
            // Remove model syllable spacing before punctuation preferences can
            // introduce intentional spaces at Chinese clause boundaries.
            result.text = VerbatimSpanMask.transforming(result.text) {
                $0.replacingOccurrences(
                    of: #"(?<=\p{Han})[\p{Zs}\t]+(?=\p{Han})"#,
                    with: "",
                    options: .regularExpression
                )
            }
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
