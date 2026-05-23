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
        let request = makeRequest(
            intent: intent,
            contextBefore: contextBefore,
            targetText: targetText,
            contextAfter: contextAfter,
            spokenInstruction: spokenInstruction,
            languageIDs: languageIDs,
            appName: appName,
            bundleID: bundleID,
            appCategory: appCategory
        )
        return try await edit(request)
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
            numberOutputPreference: AppSettings.numberOutputPreference,
            punctuationPreference: AppSettings.punctuationPreference,
            userDictionary: dictionary.sortedSnapshot()
        )
    }

    func edit(_ request: TextEditRequest) async throws -> TextEditResult {
        let (system, user) = TextEditPromptBuilder.build(for: request)
        let output = try await CorrectorFactory.shared.make().complete(
            system: system,
            user: user,
            timeoutMs: AppSettings.correctionTimeoutMs
        )
        var result = try TextEditValidator.parseAndValidate(rawOutput: output, for: request)
        result.text = LocaleTextNormalizer.normalize(result.text, languageIDs: request.languageIDs)
        result.text = TranscriptPostProcessor.clean(
            result.text,
            languageIDs: request.languageIDs,
            preserveLineBreaks: true,
            appendTerminalPunctuation: false,
            numberPreference: AppSettings.numberOutputPreference,
            punctuationPreference: AppSettings.punctuationPreference
        )
        return result
    }
}
