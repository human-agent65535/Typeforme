import Foundation

/// Builds prompts with stable system content separated from volatile transcript
/// data so the reusable portions remain cacheable.
enum PromptBuilder {
    static func build(for request: CorrectionRequest) -> (system: String, user: String) {
        (systemPrompt(for: request), userPrompt(for: request))
    }

    static func systemPrompt(for request: CorrectionRequest) -> String {
        let systemPrompt = PromptOverrideStore.readSystemPrompt() ?? BuiltInPrompts.baseSystem
        let modePrompt = PromptOverrideStore.readModePrompt(for: request.correctionMode)
            ?? BuiltInPrompts.modePrompt(request.correctionMode)
        var parts = [systemPrompt, modePrompt]

        if let asrSourceNotes = BuiltInPrompts.asrSourceNotesPrompt(for: request.sourceHypotheses) {
            parts.append(asrSourceNotes)
        }

        let additional = AppSettings.promptAdditionalSystem.trimmingCharacters(in: .whitespacesAndNewlines)
        if !additional.isEmpty {
            parts.append("""
            <user_preferences>
            Follow these preferences when they do not conflict with the core editing rules:
            \(additional)
            </user_preferences>
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    static func userPrompt(for request: CorrectionRequest) -> String {
        var parts: [String] = []
        let languageIDs = ASRLanguageSelection.validatedIDs(request.languageIDs)

        let outputPreferences = PromptOutputPreferencesPayload(
            numbers: request.numberOutputPreference.rawValue,
            numberInstruction: request.numberOutputPreference.promptInstruction,
            punctuation: request.punctuationPreference.rawValue,
            punctuationInstruction: request.punctuationPreference.promptInstruction
        )
        let context = DictationPromptContextPayload(
            appName: request.frontmostAppName ?? "",
            bundleID: request.frontmostBundleID ?? "",
            appCategory: request.appCategory.rawValue,
            languageCodes: ASRLanguageSelection.languageCodes(for: languageIDs),
            languageInstruction: LocaleTextNormalizer.promptInstruction(for: languageIDs),
            correctionMode: request.correctionMode.rawValue,
            outputPreferences: outputPreferences
        )
        let vocabularyCandidates = vocabularyCandidates(for: request)

        let asrHypotheses = request.sourceHypotheses
        let input = DictationPromptInputPayload(
            context: context,
            contextBefore: request.contextBefore,
            contextAfter: request.contextAfter,
            vocabularyCandidates: vocabularyCandidates,
            rawTranscript: request.rawTranscript,
            asrHypotheses: asrHypotheses
        )

        let json = PromptPayloadEncoder.jsonString(input)
        parts.append("""
        <input_json>
        \(json)
        </input_json>
        """)
        parts.append("Return the corrected text.")
        return parts.joined(separator: "\n")
    }

    static func vocabularyCandidates(for request: CorrectionRequest) -> [VocabularyCandidatePayload] {
        VocabularyCandidateSelector.promptPayload(
            from: request.userDictionary,
            rawText: request.rawTranscript,
            alternateTranscripts: request.asrHypotheses,
            extraContext: [
                request.frontmostAppName ?? "",
                request.frontmostBundleID ?? "",
                request.appCategory.rawValue,
                request.contextBefore,
                request.contextAfter,
            ]
        )
    }
}
