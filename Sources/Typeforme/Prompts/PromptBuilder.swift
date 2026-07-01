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
        if let reliabilityExamples = BuiltInPrompts.asrReliabilityExamplesPrompt(for: request.sourceHypotheses) {
            parts.append(reliabilityExamples)
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
            audioDurationMs: request.audioDurationMs,
            asrHypotheses: asrHypotheses
        )

        let json = PromptPayloadEncoder.jsonString(input)
        parts.append("""
        <input_json>
        \(json)
        </input_json>
        """)
        parts.append("Return exactly one JSON object and nothing else: {\"text\":\"corrected transcript\"}.")
        return parts.joined(separator: "\n")
    }

    static func formatRepairPrompt(parseError: String) -> String {
        let repair = DictationRepairPromptPayload(
            validationError: parseError
        )
        return """
        Your previous output did not satisfy the JSON contract.

        <format_error_json>
        \(PromptPayloadEncoder.jsonString(repair))
        </format_error_json>

        Rewrap the same intended final transcript from your previous output.
        Do not re-edit, improve, translate, summarize, or regenerate from input_json.
        If your previous output does not contain a determinate intended final transcript, return {"decision":"reject","text":""}.
        Otherwise return exactly one JSON object and nothing else: {"decision":"rewrap","text":"same intended final transcript"}.
        """
    }

    static func verifierPrompt(validationSignal: String, candidateText: String) -> String {
        let payload = DictationVerifierPromptPayload(
            validationSignal: validationSignal,
            candidateText: candidateText
        )
        return """
        Check whether your previous candidate text is safe to commit.

        <verification_json>
        \(PromptPayloadEncoder.jsonString(payload))
        </verification_json>

        You are checking, not editing. Default to accept unless there is clear evidence that the candidate violates the original task or validation signal.
        Return exactly one JSON object and nothing else:
        {"decision":"accept","reason_code":"ok","text":"candidate text exactly"}
        {"decision":"replace","reason_code":"minimal_fix","text":"minimal corrected text"}
        {"decision":"reject","reason_code":"unsafe","text":""}

        Rules:
        - For accept, text must exactly equal candidate_text.
        - Use replace only for a minimal fix to a clear violation such as duplicated content, concatenated ASR hypotheses, or unsafe markup.
        - Do not make stylistic improvements or re-run correction.
        - Reject if the safe final transcript is not determinate.
        """
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
